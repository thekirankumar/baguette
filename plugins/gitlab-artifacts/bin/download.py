"""Prepare a GitLab artifact; installation and workspace cleanup belong to Baguette."""

import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback
import unicodedata
from urllib.parse import quote
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_LIMIT = 3 * 1024**3
EXPANDED_LIMIT = 16 * 1024**3
DISK_RESERVE = 64 * 1024**2
CHUNK_SIZE = 1024 * 1024
MESSAGE_LIMIT = 4096  # The host's retained run-message budget, in UTF-8 bytes.
METADATA_LIMIT = 4 * 1024**2
METADATA_TIMEOUT = 30
SEARCH_PAGE_LIMIT = 100
FAILURE = {"ok": False, "message": "Invalid artifact request or host configuration"}


def redact(text, env):
    """Keep diagnostics, but never deliberately publish authentication material."""
    secrets = [value for key, value in env.items() if isinstance(value, str) and value
               and re.search(r"TOKEN|PASSWORD|SECRET|AUTHORIZATION|API_KEY|PRIVATE_KEY", key, re.I)]
    for value in sorted(secrets, key=len, reverse=True):
        text = text.replace(value, "[REDACTED]")
    text = re.sub(r"(?im)((?:authorization|proxy-authorization|private-token|job-token)\s*:\s*)[^\r\n]+",
                  r"\1[REDACTED]", text)
    text = re.sub(r"(?i)(\b(?:[\w-]*token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s&\"']+",
                  r"\1[REDACTED]", text)
    text = re.sub(r"(?i)(https?://)[^\s/@]+@", r"\1[REDACTED]@", text)
    return text


def excerpt(text, limit):
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    marker = f"\n[... truncated; original {len(data)} bytes ...]\n"
    available = max(0, limit - len(marker.encode()))
    head = available // 2
    tail = available - head
    return data[:head].decode("utf-8", errors="ignore") + marker + (data[-tail:].decode("utf-8", errors="ignore") if tail else "")


def failure(message, error, env, context=None):
    # Put causes and subprocess diagnostics BEFORE context/traceback: the host
    # retains only 4096 bytes. Bound sections after redaction, never before.
    causes, seen, current = [], set(), error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        causes.append(f"{type(current).__name__}: {current}")
        current = current.__cause__ or (current.__context__ if not current.__suppress_context__ else None)
    details = excerpt(redact(message, env), 256)
    details += "\nCauses:\n" + excerpt(redact("\n".join(reversed(causes)), env), 2400)
    if context:
        details += "\nContext:\n" + excerpt(redact(json.dumps(context, indent=2, default=str), env), 800)
    trace = redact("".join(traceback.format_exception(type(error), error, error.__traceback__)), env)
    details += "\nTraceback:\n" + excerpt(trace, MESSAGE_LIMIT - len(details.encode()) - len("\nTraceback:\n"))
    return {"ok": False, "message": details}


def diagnostic_context(request, config, env):
    # Deliberately allowlist context: never dump the request or the environment.
    context = {"workspace": env.get("BAGUETTE_RUN_DIR"),
               "configPath": str(ROOT / "config.json"),
               "PATH": env.get("PATH", os.defpath),
               "GITLAB_HOST": env.get("GITLAB_HOST"),
               "GITLAB_TOKEN": "present" if env.get("GITLAB_TOKEN") else "missing"}
    if isinstance(config, dict):
        context.update({key: config.get(key, default) for key, default in (
            ("host", None), ("projectIds", None), ("appPath", None),
            ("maxArchiveBytes", ARCHIVE_LIMIT), ("maxExpandedBytes", EXPANDED_LIMIT), ("maxEntries", 50000))})
    if isinstance(request, dict) and isinstance(request.get("args"), dict):
        context.update({key: request["args"].get(key) for key in ("projectId", "jobId")})
    return context


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(value, file, separators=(",", ":"))
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_config(path):
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def positive_integer(value):
    if type(value) is int and value > 0:
        return value
    if isinstance(value, str) and re.fullmatch(r"[1-9][0-9]{0,19}", value):
        return int(value)
    raise ValueError("Invalid identifier")


def project_reference(value):
    if type(value) is int or isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return positive_integer(value)
    if not isinstance(value, str) or not value or len(value) > 1024 or value != value.strip():
        raise ValueError("Project must be a positive numeric ID, namespace/project path or exact project name")
    if "/" in value:
        if not all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", part) for part in value.split("/")):
            raise ValueError("Invalid project path; supply an unencoded namespace/project path, not a URL")
    elif not re.fullmatch(r"[\w .-]+", value) or not any(char.isalpha() or char == "_" for char in value):
        raise ValueError("Invalid project name; supply its numeric ID or full project path")
    return value


def relative_parts(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError(f"Invalid archive path: {name!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError(f"Invalid archive path (control character): {name!r}")
    parts = tuple(name.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Invalid archive path (empty, dot or traversal segment): {name!r}")
    return parts


def policy(request, config, env, workspace):
    if not isinstance(request, dict) or type(request.get("version")) is not int or request["version"] != 1:
        raise ValueError("Invalid request")
    if request.get("command") != "gitlab-artifacts:install" or not isinstance(request.get("udid"), str) or not request["udid"]:
        raise ValueError("Invalid request")
    if request.get("workspace") != str(workspace):
        raise ValueError("Invalid workspace")
    args = request.get("args")
    if not isinstance(args, dict) or set(args) != {"projectId", "jobId"}:
        raise ValueError("Invalid arguments")
    project, job = project_reference(args["projectId"]), positive_integer(args["jobId"])
    host = config.get("host")
    if not isinstance(host, str) or len(host) > 253 or not re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*", host
    ):
        raise ValueError("Invalid configured host")
    projects = config.get("projectIds")
    if projects != "*" and (not isinstance(projects, list) or not projects
            or any(type(item) is not int or item <= 0 for item in projects)
            or type(project) is int and project not in projects):
        raise ValueError("Unapproved project")
    if not env.get("GITLAB_HOST"):
        raise ValueError("Missing GITLAB_HOST in the plugin environment")
    if env["GITLAB_HOST"] != host:
        raise ValueError(f"GITLAB_HOST {env['GITLAB_HOST']!r} does not match configured host {host!r}")
    if not env.get("GITLAB_TOKEN"):
        raise ValueError("Missing GITLAB_TOKEN in the plugin environment")
    archive_limit = config.get("maxArchiveBytes", ARCHIVE_LIMIT)
    expanded_limit = config.get("maxExpandedBytes", EXPANDED_LIMIT)
    entry_limit = config.get("maxEntries", 50000)
    if any(type(value) is not int or value <= 0 for value in (archive_limit, expanded_limit, entry_limit)):
        raise ValueError("Invalid limits")
    app_path = config.get("appPath")
    if app_path is not None:
        parts = relative_parts(app_path)
        if not parts[-1].endswith(".app"):
            raise ValueError("Invalid configured app")
    return host, project, job, archive_limit, expanded_limit, entry_limit, app_path


def stderr_excerpt(file, env):
    length = file.seek(0, os.SEEK_END)
    file.seek(0)
    if length > MESSAGE_LIMIT:
        first = file.read(MESSAGE_LIMIT).decode("utf-8", errors="ignore")
        file.seek(-MESSAGE_LIMIT, os.SEEK_END)
        last = file.read(MESSAGE_LIMIT).decode("utf-8", errors="ignore")
        output = first + f"\n[... stderr truncated; original {length} bytes ...]\n" + last
    else:
        output = file.read().decode("utf-8", errors="replace")
    return excerpt(redact(output, env), 1500) or "(empty; the process may not have started)"


def gitlab_json(workspace, host, endpoint, env):
    argv = ["glab", "api", "--method", "GET", "--hostname", host, endpoint]
    free = shutil.disk_usage(workspace).free
    if free < 2 * METADATA_LIMIT + DISK_RESERVE:
        raise ValueError(f"Insufficient disk space for project lookup: free bytes: {free}; response limit: {METADATA_LIMIT}; reserve: {DISK_RESERVE}")
    # File-backed output avoids pipe deadlocks; the child inherits the host-owned
    # process group and cannot grow either response file beyond this bound.
    with tempfile.TemporaryFile(dir=workspace) as output, tempfile.TemporaryFile(dir=workspace) as stderr:
        process = None
        try:
            def cap_file_size():
                resource.setrlimit(resource.RLIMIT_FSIZE, (METADATA_LIMIT, METADATA_LIMIT))

            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=stderr,
                                       cwd=workspace, env=dict(env), preexec_fn=cap_file_size)
            try:
                status = process.wait(timeout=METADATA_TIMEOUT)
            except BaseException:
                process.kill()
                process.wait()
                raise
            size = output.seek(0, os.SEEK_END)
            if status != 0:
                raise ValueError(f"GitLab project API failed; exit status: {status}; response bytes: {size}; limit: {METADATA_LIMIT}")
            if size > METADATA_LIMIT:
                raise ValueError(f"GitLab project metadata exceeds {METADATA_LIMIT} bytes")
            output.seek(0)
            return json.load(output)
        except Exception as error:
            raise RuntimeError(f"Command: {shlex.join(argv)}\nPATH: {env.get('PATH', os.defpath)}\n"
                               f"Project API timeout: {METADATA_TIMEOUT} seconds; response limit: {METADATA_LIMIT} bytes\n"
                               f"glab stderr:\n{stderr_excerpt(stderr, env)}") from error


def project_metadata(value):
    if (not isinstance(value, dict) or type(value.get("id")) is not int or value["id"] <= 0
            or any(not isinstance(value.get(key), str) or not value[key] for key in ("name", "path", "path_with_namespace"))
            or "/" not in value["path_with_namespace"]):
        raise ValueError("Invalid GitLab project metadata; expected positive integer id, name, path and path_with_namespace")
    project_reference(value["path_with_namespace"])
    return value


def resolve_project(workspace, host, reference, env):
    atomic_json(workspace / "progress.json", {"phase": "resolving"})
    if "/" in reference:
        return project_metadata(gitlab_json(workspace, host, "projects/" + quote(reference, safe=""), env))["id"]
    matches = {}
    for page in range(1, SEARCH_PAGE_LIMIT + 1):
        endpoint = f"projects?search={quote(reference, safe='')}&simple=true&per_page=100&page={page}&order_by=id&sort=asc"
        projects = gitlab_json(workspace, host, endpoint, env)
        if not isinstance(projects, list) or len(projects) > 100:
            raise ValueError("Invalid GitLab project search response; expected a page of at most 100 projects")
        for value in projects:
            project = project_metadata(value)
            if reference.casefold() in (project["name"].casefold(), project["path"].casefold()):
                matches[project["id"]] = project["path_with_namespace"]
        if len(matches) > 1:
            candidates = ", ".join(f"{path} (ID {identifier})" for identifier, path in sorted(matches.items()))
            raise ValueError(f"Project name {reference!r} is ambiguous: {candidates}. Supply the full project path.")
        if len(projects) < 100:
            if not matches:
                raise ValueError(f"No exact project named {reference!r} is accessible on {host}; supply the full project path or numeric ID")
            return next(iter(matches))
    raise ValueError(f"Project search exceeded {SEARCH_PAGE_LIMIT} pages; uniqueness could not be established. Supply the full project path.")


def download_archive(workspace, host, project, job, limit, env):
    path = workspace / "artifacts.zip"
    argv = ["glab", "api", "--method", "GET", "--hostname", host,
            f"projects/{project}/jobs/{job}/artifacts"]
    # A file, not PIPE: glab can emit arbitrarily verbose stderr without blocking
    # behind the parent, which is polling progress rather than draining a pipe.
    with tempfile.TemporaryFile(dir=workspace) as stderr:
        try:
            free = shutil.disk_usage(workspace).free
            if free < limit + DISK_RESERVE:
                raise ValueError(f"Insufficient disk space: free bytes: {free}; archive limit: {limit}; reserve: {DISK_RESERVE}")
            atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": 0})
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as file:
                # Bound polling overshoot at the OS boundary; inherit the core's process group.
                def cap_file_size():
                    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

                process = subprocess.Popen(
                    argv, stdin=subprocess.DEVNULL, stdout=file, stderr=stderr,
                    cwd=workspace, env=dict(env), preexec_fn=cap_file_size,
                )
                status = None
                try:
                    while True:
                        status = process.poll()
                        size = path.stat().st_size
                        if size > limit:
                            raise ValueError(f"Archive too large: downloaded bytes: {size}; limit: {limit}")
                        atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": size})
                        if status is not None:
                            if status != 0:
                                reason = f"exit status: {status}"
                                if status < 0:
                                    reason += f"; signal: {signal.Signals(-status).name}"
                                if size >= limit:
                                    reason += f"; archive reached its size limit: {limit} bytes"
                                raise ValueError(f"Download failed; {reason}")
                            break
                        free = shutil.disk_usage(workspace).free
                        if free < DISK_RESERVE:
                            raise ValueError(f"Insufficient disk space: free bytes: {free}; reserve: {DISK_RESERVE}")
                        time.sleep(0.1)
                except BaseException:
                    if status is None:
                        process.kill()
                        process.wait()
                    raise
        except Exception as error:
            size = path.stat().st_size if path.exists() else 0
            raise RuntimeError(
                f"Command: {shlex.join(argv)}\n"
                f"PATH: {env.get('PATH', os.defpath)}\n"
                f"Archive: {path}\ndownloaded bytes: {size}; archive limit: {limit}\n"
                f"glab stderr:\n{stderr_excerpt(stderr, env)}"
            ) from error
    return path


def extract_archive(path, workspace, limit, entry_limit):
    with zipfile.ZipFile(path, allowZip64=True) as archive:
        # zipfile has already loaded the central directory; bound further processing and extraction.
        if len(archive.infolist()) > entry_limit:
            raise ValueError(f"Too many ZIP entries: {len(archive.infolist())}; limit: {entry_limit}")
        entries, paths, explicit, total = [], {}, set(), 0
        for entry in archive.infolist():
            if entry.orig_filename != entry.filename or entry.flag_bits & 1:
                raise ValueError(f"Invalid ZIP entry: {entry.orig_filename!r}; flags: {entry.flag_bits}")
            parts = relative_parts(entry.filename[:-1] if entry.is_dir() else entry.filename)
            mode = entry.external_attr >> 16 if entry.create_system == 3 else 0
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG) or (kind == stat.S_IFDIR) != entry.is_dir() and kind != 0:
                raise ValueError(f"Special or inconsistent ZIP entry: {entry.filename!r}; mode: {mode:#o}")
            if entry.file_size < 0 or entry.file_size > limit or entry.is_dir() and entry.file_size != 0:
                raise ValueError(f"Expanded entry too large: {entry.filename!r}; bytes: {entry.file_size}; limit: {limit}")
            total += entry.file_size
            if total > limit:
                raise ValueError(f"Expanded archive too large at {entry.filename!r}: bytes: {total}; limit: {limit}")
            # macOS commonly aliases case and Unicode normalization, including parent directories.
            for index in range(1, len(parts) + 1):
                prefix = parts[:index]
                key = tuple(unicodedata.normalize("NFD", part).casefold() for part in prefix)
                directory = index < len(parts) or entry.is_dir()
                if key in paths and paths[key] != (prefix, True):
                    raise ValueError(f"Conflicting ZIP paths: {entry.filename!r}; existing: {paths[key][0]!r}")
                if index == len(parts):
                    if key in explicit or key in paths and not directory:
                        raise ValueError(f"Duplicate ZIP paths: {entry.filename!r}")
                    explicit.add(key)
                paths[key] = (prefix, directory)
            entries.append((entry, parts, mode))
        free = shutil.disk_usage(workspace).free
        if free < total + DISK_RESERVE:
            raise ValueError(f"Insufficient disk space: free bytes: {free}; expanded bytes: {total}; reserve: {DISK_RESERVE}")
        destination = workspace / "extracted"
        destination.mkdir(mode=0o700)
        actual_total = 0
        directories = []
        atomic_json(workspace / "progress.json", {"phase": "extracting"})
        for entry, parts, mode in entries:
            target = destination.joinpath(*parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                directories.append((target, mode & 0o777 if mode else 0o755))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            actual_entry = 0
            with archive.open(entry) as source, target.open("xb") as output:
                while True:
                    chunk = source.read(min(CHUNK_SIZE, limit - actual_total + 1))
                    if not chunk:
                        break
                    actual_total += len(chunk)
                    actual_entry += len(chunk)
                    if actual_total > limit or actual_entry > entry.file_size:
                        raise ValueError(f"Expanded archive too large at {entry.filename!r}: total bytes: {actual_total}; limit: {limit}; entry bytes: {actual_entry}; declared: {entry.file_size}")
                    free = shutil.disk_usage(workspace).free
                    if free < len(chunk) + DISK_RESERVE:
                        raise ValueError(f"Insufficient disk space: free bytes: {free}; next chunk: {len(chunk)}; reserve: {DISK_RESERVE}")
                    output.write(chunk)
            if actual_entry != entry.file_size:
                raise ValueError(f"Invalid expanded size for {entry.filename!r}: actual: {actual_entry}; declared: {entry.file_size}")
            target.chmod(mode & 0o777 if mode else 0o644)
        # Delay restrictive directory permissions until their children have been written.
        for directory, permissions in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
            directory.chmod(permissions)
    return destination


def select_app(destination, app_path):
    if app_path is not None:
        app = destination.joinpath(*relative_parts(app_path))
        if not app.is_dir():
            raise ValueError(f"Configured app not found: {app}")
        return app
    apps = []
    for parent, directories, _ in os.walk(destination):
        for name in list(directories):
            if name.endswith(".app"):
                apps.append(Path(parent) / name)
            if name.endswith((".app", ".bundle", ".framework", ".appex", ".xctest")):
                directories.remove(name)
    if len(apps) != 1:
        raise ValueError(f"No unique app: found {len(apps)}; candidates: {[app.relative_to(destination).as_posix() for app in apps]}")
    return apps[0]


def run(request, config, env):
    message = FAILURE["message"]
    try:
        workspace = Path(env["BAGUETTE_RUN_DIR"])
        if not workspace.is_absolute() or workspace.is_symlink() or not workspace.is_dir():
            raise ValueError("Invalid workspace")
        host, project, job, archive_limit, expanded_limit, entry_limit, app_path = policy(request, config, env, workspace)
        if isinstance(project, str):
            message = "GitLab project resolution failed. Check project name/path, access permissions and host configuration."
            project = resolve_project(workspace, host, project, env)
            if config["projectIds"] != "*" and project not in config["projectIds"]:
                raise ValueError(f"Unapproved project: resolved numeric project ID {project} is not in the host allowlist")
        message = "GitLab artifact download failed. Check credentials, job artifacts, download limits, and disk space."
        archive = download_archive(workspace, host, project, job, archive_limit, env)
        message = "Artifact extraction failed. Check archive contents, extraction limits, and disk space."
        extracted = extract_archive(archive, workspace, expanded_limit, entry_limit)
        message = "No unique simulator app found. Configure appPath or provide exactly one top-level app."
        app = select_app(extracted, app_path)
        result = {"ok": True, "output": {"kind": "simulator-app", "path": app.relative_to(workspace).as_posix()}}
        atomic_json(workspace / "progress.json", {"phase": "prepared"})
    except Exception as error:
        result = failure(message, error, env, diagnostic_context(request, config, env))
    atomic_json(workspace / "result.json", result)
    return result


def main():
    request, config = None, None
    try:
        request = json.load(sys.stdin)
        config = load_config(ROOT / "config.json")
        run(request, config, os.environ)
        return 0
    except Exception as error:
        result = failure(FAILURE["message"], error, os.environ, diagnostic_context(request, config, os.environ))
        try:
            workspace = Path(os.environ["BAGUETTE_RUN_DIR"])
            if workspace.is_absolute() and workspace.is_dir() and not workspace.is_symlink():
                atomic_json(workspace / "result.json", result)
                return 0
        except Exception as publication_error:
            result = failure(result["message"] + "\nCould not publish result.json.", publication_error, os.environ)
        print(result["message"], file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

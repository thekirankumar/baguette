"""Prepare a GitLab artifact; installation and workspace cleanup belong to Baguette."""

import json
import os
from pathlib import Path
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_LIMIT = 3 * 1024**3
EXPANDED_LIMIT = 16 * 1024**3
DISK_RESERVE = 64 * 1024**2
CHUNK_SIZE = 1024 * 1024
FAILURE = {"ok": False, "message": "Invalid artifact request or host configuration"}


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


def relative_parts(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError("Invalid archive path")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError("Invalid archive path")
    parts = tuple(name.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("Invalid archive path")
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
    project, job = positive_integer(args["projectId"]), positive_integer(args["jobId"])
    host = config.get("host")
    if not isinstance(host, str) or len(host) > 253 or not re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*", host
    ):
        raise ValueError("Invalid configured host")
    projects = config.get("projectIds")
    if projects != "*" and (not isinstance(projects, list) or any(type(item) is not int or item <= 0 for item in projects) or project not in projects):
        raise ValueError("Unapproved project")
    if env.get("GITLAB_HOST") != host or not env.get("GITLAB_TOKEN"):
        raise ValueError("Missing host credentials")
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


def download_archive(workspace, host, project, job, limit, env):
    if shutil.disk_usage(workspace).free < limit + DISK_RESERVE:
        raise ValueError("Insufficient disk space")
    path = workspace / "artifacts.zip"
    atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": 0})
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as file:
        # Bound polling overshoot at the OS boundary; inherit the core's process group.
        def cap_file_size():
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))

        process = subprocess.Popen(
            ["glab", "api", "--method", "GET", "--hostname", host,
             f"projects/{project}/jobs/{job}/artifacts"],
            stdin=subprocess.DEVNULL, stdout=file, stderr=subprocess.DEVNULL,
            cwd=workspace, env=dict(env), preexec_fn=cap_file_size,
        )
        status = None
        try:
            while True:
                status = process.poll()
                size = path.stat().st_size
                if size > limit:
                    raise ValueError("Archive too large")
                atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": size})
                if status is not None:
                    if status != 0:
                        raise ValueError("Download failed")
                    break
                if shutil.disk_usage(workspace).free < DISK_RESERVE:
                    raise ValueError("Insufficient disk space")
                time.sleep(0.1)
        except BaseException:
            if status is None:
                process.kill()
                process.wait()
            raise
    return path


def extract_archive(path, workspace, limit, entry_limit):
    with zipfile.ZipFile(path, allowZip64=True) as archive:
        # zipfile has already loaded the central directory; bound further processing and extraction.
        if len(archive.infolist()) > entry_limit:
            raise ValueError("Too many ZIP entries")
        entries, paths, explicit, total = [], {}, set(), 0
        for entry in archive.infolist():
            if entry.orig_filename != entry.filename or entry.flag_bits & 1:
                raise ValueError("Invalid ZIP entry")
            parts = relative_parts(entry.filename[:-1] if entry.is_dir() else entry.filename)
            mode = entry.external_attr >> 16 if entry.create_system == 3 else 0
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG) or (kind == stat.S_IFDIR) != entry.is_dir() and kind != 0:
                raise ValueError("Special or inconsistent ZIP entry")
            if entry.file_size < 0 or entry.file_size > limit or entry.is_dir() and entry.file_size != 0:
                raise ValueError("Expanded entry too large")
            total += entry.file_size
            if total > limit:
                raise ValueError("Expanded archive too large")
            # macOS commonly aliases case and Unicode normalization, including parent directories.
            for index in range(1, len(parts) + 1):
                prefix = parts[:index]
                key = tuple(unicodedata.normalize("NFD", part).casefold() for part in prefix)
                directory = index < len(parts) or entry.is_dir()
                if key in paths and paths[key] != (prefix, True):
                    raise ValueError("Conflicting ZIP paths")
                if index == len(parts):
                    if key in explicit or key in paths and not directory:
                        raise ValueError("Duplicate ZIP paths")
                    explicit.add(key)
                paths[key] = (prefix, directory)
            entries.append((entry, parts, mode))
        if shutil.disk_usage(workspace).free < total + DISK_RESERVE:
            raise ValueError("Insufficient disk space")
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
                        raise ValueError("Expanded archive too large")
                    if shutil.disk_usage(workspace).free < len(chunk) + DISK_RESERVE:
                        raise ValueError("Insufficient disk space")
                    output.write(chunk)
            if actual_entry != entry.file_size:
                raise ValueError("Invalid expanded size")
            target.chmod(mode & 0o777 if mode else 0o644)
        # Delay restrictive directory permissions until their children have been written.
        for directory, permissions in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
            directory.chmod(permissions)
    return destination


def select_app(destination, app_path):
    if app_path is not None:
        app = destination.joinpath(*relative_parts(app_path))
        if not app.is_dir():
            raise ValueError("Configured app not found")
        return app
    apps = []
    for parent, directories, _ in os.walk(destination):
        for name in list(directories):
            if name.endswith(".app"):
                apps.append(Path(parent) / name)
            if name.endswith((".app", ".bundle", ".framework", ".appex", ".xctest")):
                directories.remove(name)
    if len(apps) != 1:
        raise ValueError("No unique app")
    return apps[0]


def run(request, config, env):
    workspace = Path(env["BAGUETTE_RUN_DIR"])
    message = FAILURE["message"]
    try:
        if not workspace.is_absolute() or workspace.is_symlink() or not workspace.is_dir():
            raise ValueError("Invalid workspace")
        host, project, job, archive_limit, expanded_limit, entry_limit, app_path = policy(request, config, env, workspace)
        message = "GitLab artifact download failed. Check credentials, job artifacts, download limits, and disk space."
        archive = download_archive(workspace, host, project, job, archive_limit, env)
        message = "Artifact extraction failed. Check archive contents, extraction limits, and disk space."
        extracted = extract_archive(archive, workspace, expanded_limit, entry_limit)
        message = "No unique simulator app found. Configure appPath or provide exactly one top-level app."
        app = select_app(extracted, app_path)
        result = {"ok": True, "output": {"kind": "simulator-app", "path": app.relative_to(workspace).as_posix()}}
        atomic_json(workspace / "progress.json", {"phase": "prepared"})
    except Exception:
        # Never surface subprocess output, credentials, request data, or host filesystem paths.
        result = {"ok": False, "message": message}
    atomic_json(workspace / "result.json", result)
    return result


def main():
    try:
        request = json.load(sys.stdin)
        config = load_config(ROOT / "config.json")
        run(request, config, os.environ)
        return 0
    except Exception:
        result = FAILURE.copy()
        try:
            workspace = Path(os.environ["BAGUETTE_RUN_DIR"])
            if workspace.is_absolute() and workspace.is_dir() and not workspace.is_symlink():
                atomic_json(workspace / "result.json", result)
                return 0
        except Exception:
            pass
    return 1


if __name__ == "__main__":
    sys.exit(main())

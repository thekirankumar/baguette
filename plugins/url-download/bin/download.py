"""Prepare a URL download; the host owns installation, cancellation and cleanup."""

from email.message import Message
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import artifact


ROOT = Path(__file__).resolve().parents[1]
FAILURE = "Invalid URL download request or host configuration"
REDIRECTS = {301, 302, 303, 307, 308}


def url_secrets(url):
    query = urllib.parse.urlsplit(url).query
    return ([value for _, value in urllib.parse.parse_qsl(query)]
            + [part.split("=", 1)[1] for part in query.split("&") if "=" in part])


def invocation_secrets(request, env):
    secrets = [value for key, value in env.items()
               if re.search(r"TOKEN|PASSWORD|SECRET|AUTHORIZATION|API_KEY|PRIVATE_KEY", key, re.I)]
    if isinstance(request, dict):
        secrets.append(request.get("token"))
        args = request.get("args")
        if isinstance(args, dict):
            headers = args.get("headers")
            if isinstance(headers, dict):
                secrets.extend(headers.values())
                # Also hide a bearer credential when a server echoes only its token.
                for value in headers.values():
                    if isinstance(value, str) and value.lower().startswith(("bearer ", "basic ")):
                        secrets.append(value.split(" ", 1)[1])
            if isinstance(args.get("url"), str):
                try:
                    secrets.extend(url_secrets(args["url"]))
                except ValueError:
                    pass
    return secrets


def context_for(request, config, env):
    context = {"workspace": env.get("BAGUETTE_RUN_DIR"), "configPath": str(ROOT / "config.json")}
    if isinstance(request, dict) and isinstance(request.get("args"), dict):
        context["downloadURL"] = request["args"].get("url")
        headers = request["args"].get("headers")
        if isinstance(headers, dict):
            context["headerNames"] = list(headers)
    if isinstance(config, dict):
        context.update({key: config.get(key) for key in (
            "allowedHosts", "allowHTTP", "maxArchiveBytes", "maxExpandedBytes", "maxEntries",
            "requestTimeoutSeconds", "maxRedirects", "appPath")})
    return context


def validate_url(url, config):
    if not isinstance(url, str) or not url or any(ord(char) <= 32 or ord(char) == 127 for char in url):
        raise ValueError("Invalid download URL: empty or contains whitespace/control characters")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.fragment:
        raise ValueError("Download URL must be HTTP(S), have a host and have no fragment")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("URL userinfo is not permitted; supply authorization in args.headers")
    port = parsed.port  # Validate the port before making a connection.
    host = parsed.hostname.lower()
    allowed = config["allowedHosts"]
    if allowed != "*" and host not in [item.lower() for item in allowed]:
        raise ValueError(f"Unapproved download host: {host}")
    if parsed.scheme == "http" and not config.get("allowHTTP", False):
        raise ValueError("HTTP download refused; HTTPS is required unless host policy enables allowHTTP")
    return parsed.scheme, host, port or (443 if parsed.scheme == "https" else 80)


def policy(request, config, workspace):
    if not isinstance(request, dict) or type(request.get("version")) is not int or request["version"] != 1:
        raise ValueError("Invalid request version; expected integer 1")
    if request.get("command") != "url-download:install" or not isinstance(request.get("udid"), str) or not request["udid"]:
        raise ValueError("Expected url-download:install and a target simulator udid")
    if request.get("workspace") != str(workspace):
        raise ValueError("Request workspace does not match BAGUETTE_RUN_DIR")
    args = request.get("args")
    if not isinstance(args, dict) or "url" not in args or set(args) - {"url", "headers"}:
        raise ValueError("Expected args.url and optional args.headers; no policy overrides are permitted")
    if not isinstance(config, dict):
        raise ValueError("Host configuration must be a JSON object")
    allowed = config.get("allowedHosts")
    if allowed != "*" and (not isinstance(allowed, list) or any(
        not isinstance(host, str) or not host or any(char in host for char in "/:@* \r\n") for host in allowed
    )):
        raise ValueError("allowedHosts must be a list of exact hostnames or explicitly '*'")
    if type(config.get("allowHTTP", False)) is not bool:
        raise ValueError("allowHTTP must be a boolean")
    limits = {"maxArchiveBytes": artifact.ARCHIVE_LIMIT, "maxExpandedBytes": artifact.EXPANDED_LIMIT,
              "maxEntries": 50000, "requestTimeoutSeconds": 30, "maxRedirects": 5}
    for key, default in limits.items():
        value = config.get(key, default)
        if type(value) is not int or value < (0 if key == "maxRedirects" else 1):
            raise ValueError(f"Invalid {key}: expected {'nonnegative' if key == 'maxRedirects' else 'positive'} integer")
        limits[key] = value
    app_path = config.get("appPath")
    if app_path is not None and not artifact.relative_parts(app_path)[-1].endswith(".app"):
        raise ValueError("Configured appPath must identify a .app directory")
    headers = args.get("headers", {})
    if not isinstance(headers, dict):
        raise ValueError("args.headers must be an object of header names to string values")
    blocked = {"host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
               "proxy-connection", "upgrade", "te", "trailer", "accept-encoding"}
    names = set()
    for key, value in headers.items():
        if not isinstance(key, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", key):
            raise ValueError("Invalid header name; expected an HTTP token")
        if key.lower() in blocked or key.lower() in names:
            raise ValueError(f"Transport, proxy or duplicate header is not permitted: {key}")
        if not isinstance(value, str) or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError(f"Invalid header value for {key}; expected a string with no control characters")
        value.encode("latin-1")  # urllib/http.client require Latin-1 header values.
        names.add(key.lower())
    validate_url(args["url"], config)
    return args["url"], dict(headers), limits, app_path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def open_response(url, headers, timeout):
    # No ambient proxy credentials, cookies, .netrc or automatic auth forwarding.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity", **headers}, method="GET")
    try:
        return opener.open(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        return error  # Status and a bounded error-body excerpt are handled together.


def download_archive(url, headers, config, limits, workspace, context, secrets):
    path = workspace / "download.bin"
    limit = limits["maxArchiveBytes"]
    free = shutil.disk_usage(workspace).free
    if free < limit + artifact.DISK_RESERVE:
        raise ValueError(f"Insufficient disk space: free bytes: {free}; archive limit: {limit}; reserve: {artifact.DISK_RESERVE}")
    artifact.atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": 0})
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        for redirect in range(limits["maxRedirects"] + 1):
            origin = validate_url(url, config)
            context["currentURL"] = url
            # Remember redirect-generated query secrets too, before any error body is surfaced.
            secrets.extend(url_secrets(url))
            response = open_response(url, headers, limits["requestTimeoutSeconds"])
            try:
                status = response.status
                context["httpStatus"] = status
                if status in REDIRECTS:
                    location = response.headers.get("Location")
                    if not location or redirect == limits["maxRedirects"]:
                        raise ValueError(f"Download redirect failed: missing Location or exceeded {limits['maxRedirects']} redirects")
                    target = urllib.parse.urljoin(url, location)
                    try:
                        next_origin = validate_url(target, config)
                    except ValueError as error:
                        raise ValueError(f"Download redirect refused: {error}") from error
                    if origin[0] == "https" and next_origin[0] == "http":
                        raise ValueError("Download redirect refused: HTTPS to HTTP downgrade")
                    if next_origin != origin:
                        headers = {}
                    url = target
                    continue
                if status != 200:
                    body = response.read(artifact.MESSAGE_LIMIT).decode("utf-8", errors="replace")
                    raise ValueError(f"HTTP {status} {getattr(response, 'reason', '')}; response body (up to 4096 bytes):\n{body}")
                encoding = response.headers.get("Content-Encoding", "identity").lower()
                if encoding != "identity":
                    raise ValueError(f"Unexpected Content-Encoding: {encoding}; expected identity")
                declared = response.headers.get("Content-Length")
                expected = None
                if declared is not None:
                    if not re.fullmatch(r"[0-9]+", declared):
                        raise ValueError(f"Invalid Content-Length: {declared!r}")
                    expected = int(declared)
                    context["contentLength"] = expected
                    if expected > limit:
                        raise ValueError(f"Download exceeds archive limit: Content-Length: {expected}; limit: {limit}")
                size = 0
                while True:
                    try:
                        chunk = response.read1(min(artifact.CHUNK_SIZE, limit - size + 1))
                    except http.client.IncompleteRead as error:
                        raise ValueError(f"Truncated HTTP response: received {size + len(error.partial)} bytes; Content-Length: {expected}") from error
                    if not chunk:
                        break
                    if size + len(chunk) > limit:
                        raise ValueError(f"Download exceeds archive limit: received at least {size + len(chunk)} bytes; limit: {limit}")
                    free = shutil.disk_usage(workspace).free
                    if free < len(chunk) + artifact.DISK_RESERVE:
                        raise ValueError(f"Insufficient disk space: free bytes: {free}; chunk: {len(chunk)}; reserve: {artifact.DISK_RESERVE}")
                    output.write(chunk)
                    size += len(chunk)
                    context["downloadedBytes"] = size
                    artifact.atomic_json(workspace / "progress.json", {"phase": "downloading", "downloadedBytes": size})
                if expected is not None and size != expected:
                    raise ValueError(f"Truncated HTTP response: downloaded bytes: {size}; Content-Length: {expected}")
                return path, url, response.headers
            finally:
                response.close()


def prepare(path, url, headers, limits, app_path, workspace):
    message = Message()
    message["Content-Disposition"] = headers.get("Content-Disposition", "")
    filename = message.get_filename() or urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])
    extension = Path(filename).suffix.lower()
    with zipfile.ZipFile(path, allowZip64=True) as archive:
        entries, total = artifact.checked_entries(archive, limits["maxExpandedBytes"], limits["maxEntries"])
        ipa_layout = any(len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app")
                         and parts[2] == "Info.plist" for _, parts, _ in entries)
        if extension == ".ipa" or extension != ".zip" and ipa_layout:
            artifact.validate_ipa(archive, entries, workspace, limits["maxExpandedBytes"])
            ipa = workspace / "download.ipa"
            path.replace(ipa)
            return ipa
        extracted = artifact.extract_archive(archive, entries, total, workspace, limits["maxExpandedBytes"])
    return artifact.select_app(extracted, app_path)


def run(request, config, env):
    context, secrets = context_for(request, config, env), invocation_secrets(request, env)
    message = FAILURE
    workspace = Path(env["BAGUETTE_RUN_DIR"])
    try:
        if not workspace.is_absolute() or workspace.is_symlink() or not workspace.is_dir():
            raise ValueError("Invalid workspace")
        url, headers, limits, app_path = policy(request, config, workspace)
        message = "URL artifact download failed."
        path, final_url, response_headers = download_archive(url, headers, config, limits, workspace, context, secrets)
        message = "Artifact preparation failed. Check archive contents, limits, disk space and app selection."
        app = prepare(path, final_url, response_headers, limits, app_path, workspace)
        artifact.atomic_json(workspace / "progress.json", {"phase": "prepared"})
        result = {"ok": True, "output": {"kind": "simulator-app", "path": app.relative_to(workspace).as_posix()}}
    except Exception as error:
        result = artifact.failure(message, error, context, secrets)
    artifact.atomic_json(workspace / "result.json", result)
    return result


def main():
    request, config = None, None
    try:
        request = json.load(sys.stdin)
        with (ROOT / "config.json").open(encoding="utf-8") as file:
            config = json.load(file)
        run(request, config, os.environ)
        return 0
    except Exception as error:
        secrets = invocation_secrets(request, os.environ)
        result = artifact.failure(FAILURE, error, context_for(request, config, os.environ), secrets)
        try:
            workspace = Path(os.environ["BAGUETTE_RUN_DIR"])
            if workspace.is_absolute() and workspace.is_dir() and not workspace.is_symlink():
                artifact.atomic_json(workspace / "result.json", result)
                return 0
        except Exception as publication_error:
            result = artifact.failure("Could not publish result.json.", publication_error, {}, secrets)
        print(result["message"], file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

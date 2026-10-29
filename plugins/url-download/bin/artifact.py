"""Self-contained archive safety and diagnostics, bundled with the URL plugin.

Keep the ZIP rules aligned with the GitLab plugin. Plugins are installed alone,
so this module deliberately has no dependency on a sibling plugin checkout.
"""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import traceback
import unicodedata
import zipfile


ARCHIVE_LIMIT = 3 * 1024**3
EXPANDED_LIMIT = 16 * 1024**3
DISK_RESERVE = 64 * 1024**2
CHUNK_SIZE = 1024 * 1024
MESSAGE_LIMIT = 4096


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


def excerpt(text, limit):
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    marker = f"\n[... truncated; original {len(data)} bytes ...]\n"
    available = max(0, limit - len(marker.encode()))
    head, tail = available // 2, available - available // 2
    return data[:head].decode("utf-8", errors="ignore") + marker + (data[-tail:].decode("utf-8", errors="ignore") if tail else "")


def redact(text, secrets):
    values = sorted({value for value in secrets if isinstance(value, str) and value}, key=len, reverse=True)
    if values:
        # Substitute in one pass so short values cannot corrupt the redaction marker.
        text = re.sub("|".join(re.escape(value) for value in values), "[REDACTED]", text)
    text = re.sub(r"(?im)((?:authorization|proxy-authorization|private-token|job-token)\s*:\s*)[^\r\n]+",
                  r"\1[REDACTED]", text)
    text = re.sub(r"(?i)(https?://)[^\s/@]+@", r"\1[REDACTED]@", text)
    # Strip all query values, including unfamiliar signed-URL parameter names.
    return re.sub(r"([?&][^\s=&#]+)=([^\s&#\"']*)", r"\1=[REDACTED]", text)


def failure(message, error, context, secrets):
    causes, seen, current = [], set(), error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        causes.append(f"{type(current).__name__}: {current}")
        current = current.__cause__ or (current.__context__ if not current.__suppress_context__ else None)
    details = excerpt(redact(message, secrets), 256)
    details += "\nCauses:\n" + excerpt(redact("\n".join(reversed(causes)), secrets), 2400)
    details += "\nContext:\n" + excerpt(redact(json.dumps(context, indent=2, default=str), secrets), 800)
    trace = redact("".join(traceback.format_exception(type(error), error, error.__traceback__)), secrets)
    details += "\nTraceback:\n" + excerpt(trace, MESSAGE_LIMIT - len(details.encode()) - len("\nTraceback:\n"))
    return {"ok": False, "message": details}


def relative_parts(name):
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError(f"Invalid archive path: {name!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError(f"Invalid archive path (control character): {name!r}")
    parts = tuple(name.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Invalid archive path (empty, dot or traversal segment): {name!r}")
    return parts


def checked_entries(archive, limit, entry_limit):
    """Validate the entire directory before extraction or direct IPA handoff."""
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
    return entries, total


def extract_archive(archive, entries, total, workspace, limit):
    free = shutil.disk_usage(workspace).free
    if free < total + DISK_RESERVE:
        raise ValueError(f"Insufficient disk space: free bytes: {free}; expanded bytes: {total}; reserve: {DISK_RESERVE}")
    destination = workspace / "extracted"
    destination.mkdir(mode=0o700)
    actual_total, directories = 0, []
    atomic_json(workspace / "progress.json", {"phase": "extracting"})
    for entry, parts, mode in entries:
        target = destination.joinpath(*parts)
        if entry.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            directories.append((target, mode & 0o777 if mode else 0o755))
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            actual_total += transfer_entry(archive, entry, output, workspace, limit - actual_total)
        target.chmod(mode & 0o777 if mode else 0o644)
    for directory, permissions in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
        directory.chmod(permissions)
    return destination


def transfer_entry(archive, entry, output, workspace, limit):
    actual = 0
    with archive.open(entry) as source:
        while True:
            chunk = source.read(min(CHUNK_SIZE, limit - actual + 1))
            if not chunk:
                break
            actual += len(chunk)
            if actual > limit or actual > entry.file_size:
                raise ValueError(f"Expanded archive too large at {entry.filename!r}: bytes: {actual}; remaining limit: {limit}; declared: {entry.file_size}")
            if output is not None:
                free = shutil.disk_usage(workspace).free
                if free < len(chunk) + DISK_RESERVE:
                    raise ValueError(f"Insufficient disk space: free bytes: {free}; chunk: {len(chunk)}; reserve: {DISK_RESERVE}")
                output.write(chunk)
    if actual != entry.file_size:
        raise ValueError(f"Invalid expanded size for {entry.filename!r}: actual: {actual}; declared: {entry.file_size}")
    return actual


def validate_ipa(archive, entries, workspace, limit):
    # Read through zipfile for CRC and actual-size validation, but write no
    # expanded files: the original IPA is handed directly to the host.
    atomic_json(workspace / "progress.json", {"phase": "validating"})
    total = 0
    for entry, _, _ in entries:
        if not entry.is_dir():
            total += transfer_entry(archive, entry, None, workspace, limit - total)


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
                apps.append(os.path.join(parent, name))
            if name.endswith((".app", ".bundle", ".framework", ".appex", ".xctest")):
                directories.remove(name)
    if len(apps) != 1:
        raise ValueError(f"No unique app: found {len(apps)}; candidates: {apps}")
    return Path(apps[0])

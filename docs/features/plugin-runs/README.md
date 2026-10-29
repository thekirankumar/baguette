---
description: Start, poll and cancel server-owned background plugin runs, including GitLab artifact preparation and simulator installation. Use for long-running plugin work and host integration.
---

# Background Plugin Runs

Background commands outlive the HTTP request that starts them. The server owns
their process, workspace, optional app installation and final status. Short
panel commands keep the [synchronous contract](../plugins/authoring.md#the-command-contract).
For URL downloads with per-call headers, use [url-download](../url-download/README.md).

## Configure the GitLab Example

From the baguette checkout, configure `plugins/gitlab-artifacts/config.json`
on the host before starting the server:

```json
{
  "host": "gitlab.example.com",
  "projectIds": [123],
  "appPath": "build/MyApp.app",
  "maxArchiveBytes": 3221225472,
  "maxExpandedBytes": 17179869184,
  "maxEntries": 50000
}
```

`host` is a hostname, not a URL. `projectIds` explicitly allows numeric project
IDs; `"*"` allows every project the token can access, and `[]` disables downloads.
The local example allows all projects on `gitlab.phonepe.com`. `appPath` is optional
and relative to the artifact archive. Without it, exactly one outer `.app`
must be found; nested apps inside app bundles are not separate candidates.
Supply a simulator build, not an iPhone-only build.

The configured limits are 3 GiB downloaded, 16 GiB expanded and 50,000 ZIP
entries. The downloader bounds the archive file size and checks declared and
actual expanded bytes, free disk space and unsafe/conflicting archive paths.
It rejects symlinks and special entries. These are not memory limits:
Python's `zipfile` loads the central-directory metadata before the entry-count
check, so adversarial metadata's initial memory use is not hard capped.

Provide `GITLAB_TOKEN` and `GITLAB_HOST` in the server's host environment;
`GITLAB_HOST` must match the configured hostname. Never put credentials in
request args. The manifest explicitly requests these two names through
`background.environment`, along with `HOME` for glab's configuration directory;
other host variables are not inherited, apart from
the host `PATH`. Install `python3` and `glab` on that `PATH`. Background
execution also depends on the host's `/usr/bin/perl` process-group wrapper.

```bash
# GITLAB_TOKEN is already provisioned in the host environment.
export GITLAB_HOST=gitlab.example.com
baguette serve --plugin-dir plugins
```

`--plugin-dir` names the root containing plugin directories, not
`plugins/gitlab-artifacts` itself. It is an existing repeatable authoring flag
that shadows installed plugins of the same name. The example contributes a
command, not a browser panel.

## Start and Poll

```bash
BASE=http://127.0.0.1:8421 # Include /subpath here if the server is mounted there.
UDID='<UDID>'
curl -i -X POST "$BASE/plugins/gitlab-artifacts/commands/install/runs?udid=$UDID" \
  -H 'Content-Type: application/json' \
  --data '{"args":{"projectId":123,"jobId":456}}'
# 202 Accepted; Location: /runs/<id>.json (with the mount prefix, if any)
curl "$BASE/runs/<id>.json"
```

Start accepts only an optional `args` object in a JSON body of at most 64 KiB;
an empty body is also valid. The GitLab example requires exactly `projectId`
and `jobId`, each a positive integer or numeric string. Host, token, executable,
archive limits and app selection are host policy, not request overrides.

The `202` body is run JSON, initially `state: "queued"`, with `id`, `command`,
optional `udid` and `createdAt`. Follow its `Location` and poll. Status reads
answer `200`, including failures; inspect `state` and `message`, not just HTTP
success. A failed run after cleanup can look like:

```json
{
  "id": "<id>",
  "command": "gitlab-artifacts:install",
  "udid": "<UDID>",
  "createdAt": 0,
  "state": "failed",
  "message": "Artifact extraction failed. Check archive contents, extraction limits, and disk space.\nCauses:\nBadZipFile: File is not a zip file\n..."
}
```

States are `queued`, `running`, `succeeded`, `failed`, `cancelled`. Optional
`phase` and `downloadedBytes` describe progress; `installing` is a phase, not
a state. Messages are bounded and known request/environment secrets redacted;
authors must still avoid putting secrets in reports. Run responses use
`Cache-Control: no-store`. There are no webhooks, push transports or actual
push failure callbacks; an outer integration must poll and notify its users.

The GitLab plugin includes the actual cause, command and stderr in failed-run
messages. See [GitLab failure diagnostics](gitlab-diagnostics.md) for examples and truncation limits.

## CLI Workflow

These clients talk to the running server; they do not execute a local plugin:

```bash
RUN=$(baguette plugin start gitlab-artifacts:install --udid "$UDID" \
  --url "$BASE" --args '{"projectId":123,"jobId":456}' | jq -r .id)
baguette plugin status "$RUN" --url "$BASE"
baguette plugin wait "$RUN" --url "$BASE"
# Or request cancellation while preparation is still running:
baguette plugin cancel "$RUN" --url "$BASE"
```

`start`, `status` and `cancel` print current JSON. `wait` polls once a second,
prints only terminal JSON and exits unsuccessfully for `failed` or `cancelled`.
Every `--url` retains its mounted prefix. `baguette plugin run` and the short
command endpoint refuse background commands; use `start` or the runs endpoint.

## Background Author Contract

Add `background` to a contributed command alongside its existing `run` argv:

```json
{
  "background": {
    "timeoutSeconds": 3600,
    "environment": ["GITLAB_TOKEN", "GITLAB_HOST", "HOME"]
  }
}
```

The default preparation timeout is 3,600 seconds; valid values are 1...86,400.
Environment names must be identifiers and cannot be `PATH` or `BAGUETTE_*`.
The process cwd is the plugin directory. The host supplies `BAGUETTE_RUN_DIR`,
`BAGUETTE_URL`, `BAGUETTE_TOKEN` and, when targeted, `BAGUETTE_UDID`. Stdin is
one JSON context with `version: 1`, `command`, `url`, `token`, `workspace`,
optional `udid` and optional `args`. The per-run capability grant is revoked
when preparation ends. Stdout and stderr are discarded, not status channels.

Atomically publish `result.json` inside the workspace before exiting:

```json
{"ok":true,"output":{"kind":"simulator-app","path":"extracted/build/MyApp.app"}}
```

The final contract is `{ "ok": true, "output": ... }` with optional `output`.
A generic non-app run succeeds with `{ "ok": true }`; app-capable runs require output.
Output is supported
only for plugins declaring `apps` and started with a target `udid`; it must be
`kind: "simulator-app"` with an existing `.app` directory or regular `.ipa` file
at a workspace-relative path. Absolute/dot/traversal paths and escaping symlinks
are refused; IPA symlinks are refused. Baguette installs the app, not the plugin.

For a handled failure, atomically publish `{ "ok": false, "message": "..." }`
with either exit 0 or nonzero; a valid failure message is preserved. Nonzero
exits never install output and fall back to `background command exited <status>`.
Missing or invalid results fail. Result and progress files must be regular,
non-symlink files of at most 64 KiB. Optional atomic `progress.json` contains
`phase` and/or nonnegative integer `downloadedBytes`; malformed progress is
ignored. Write a sibling temporary file and rename it into place for publication.

## Ownership and Limits

- The entire workspace, including ZIPs, extracted `.app`s and result/progress
  files, is deleted on success, failure and cancellation. Only status remains.
  Terminal status is published after cleanup; a cleanup failure publishes
  `failed` with `background workspace cleanup failed`, not a cleanup guarantee.
- At most two background runs are active, and at most one targets a given
  simulator. This excludes only other background runs, not general simulator
  operations or global simulator locks. Busy/capacity conflicts answer `409`.
- Each preparing workspace has a periodic 24 GiB disk bound, checked once a
  second. This is not a hard filesystem quota or a process sandbox; writes can
  overshoot between checks. Plugins run with the host user's permissions.
- Timeout covers preparation only, not app installation. Preparation cancellation
  sends `SIGTERM`, then `SIGKILL` after two seconds. Cancel answers `202` until
  cleanup completes, `200` if already terminal, and `409` during installation.
   Group cleanup is checked before completion; inconclusive cleanup fails the run.
   Descendants that deliberately detach are not covered. Wait for terminal status.
- Up to 1,000 statuses are retained without eviction until restart; when full,
  starts are refused. The default root is a unique temporary directory per server
  lifetime, so old statuses are unavailable after restart. There is no CLI
  retention flag or restart/resume contract.
- Graceful shutdown stops preparation and waits for active installation and
  cleanup. An abrupt crash can leave residual state and workspaces; cleanup
  cannot be guaranteed, and runs cannot resume.

## Host Integration

Run-control routes use the server's Host/Origin trust checks, not user
authentication. Keep authentication and authorization at a trusted proxy;
see [proxy setup](../../serve.md#proxy-subpaths). Credentials stay on the host.
Simmer's proxy allowlist does not automatically forward these new routes:
start/status/cancel forwarding and any polling-based notifications need explicit
outer integration. A simulator lease is not created by starting a plugin run.

See [serve routes](../../serve.md#routes) and [plugin authoring](../plugins/authoring.md).

# GitLab artifact failure diagnostics

The GitLab artifact plugin reports diagnostic details in the existing failed-run
`message` field. Poll the run to completion, or use `baguette plugin wait` as shown
in the [background-run workflow](README.md#cli-workflow). A skill or integration
should display that field, not replace it with a generic download failure.

## What failures explain

- **Missing executable:** `FileNotFoundError`, the attempted `glab api` command,
  and the plugin's executable search `PATH`. Install `glab` on the server host's
  `PATH`; installing it only on the machine invoking the skill is not sufficient.
- **GitLab/network failures:** exit status or termination signal, command,
  host/project/job endpoint, downloaded byte count, archive limit and stderr.
  HTTP errors, permission denials, expired artifacts, TLS failures and other
  explanations appear when `glab` emits them.
- **Host setup:** missing `GITLAB_TOKEN` or `GITLAB_HOST`, a host mismatch,
  malformed input/configuration, missing config files and other Python errors.
- **Project resolution:** missing/ambiguous names, path lookup failures, denied
  resolved IDs and bounded metadata lookup errors. See [project references](gitlab-projects.md).
- **Preparation:** free/required disk bytes, unsafe archive entry names,
  size/count limits, missing configured apps and ambiguous app candidates.
- **Debugging context:** workspace/config paths, configured limits, identifiers,
  exception types, chained causes and as much traceback as the message allows.

For example, the beginning of a missing-executable message looks like:

```text
GitLab artifact download failed. Check credentials, job artifacts, download limits, and disk space.
Causes:
FileNotFoundError: [Errno 2] No such file or directory: 'glab'
RuntimeError: Command: glab api --method GET --hostname gitlab.example.com projects/123/jobs/456/artifacts
PATH: /usr/bin:/bin
```

## Redaction and limits

Diagnostics are verbose by default; no debug flag is needed. Known sensitive
environment values and common authorization-header, token/password assignment
and URL-userinfo forms are redacted before publication. The plugin does not dump
the full environment, raw request or binary artifact body. Paths, hostnames and
project/job IDs are intentionally visible; review diagnostics before sharing.
Redaction is not a guarantee against every possible secret in third-party output.

The host retains **at most 4,096 UTF-8 bytes** per failure message. The plugin
keeps its result within that unchanged budget, prioritizing causes, command and
stderr over context and traceback. Long sections include an explicit truncation
notice and excerpts from both ends; a verbose stderr file is not loaded entirely
into memory. This also keeps `result.json` below the host's 64 KiB file limit.
Complete, unbounded logs are not available through run status. Workspace files
are deleted after the run; there is no retained full-log file.

When a structured failure can be published, the plugin exits zero and the run
still fails through `ok: false`. If even `result.json` cannot be written, the
script emits redacted diagnostics to stderr and exits nonzero. The background
host discards process stderr, so a skill sees the host's fallback error in that
case; stderr is useful only when running the script directly for debugging.

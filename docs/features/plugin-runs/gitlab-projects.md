# GitLab project IDs, paths and names

`gitlab-artifacts:install` keeps its existing `projectId` argument for backward
compatibility. It accepts a positive integer ID, a numeric string, an unencoded
full namespace/project path, or a unique exact project name:

```json
{"args":{"projectId":301,"jobId":18611231}}
{"args":{"projectId":"ios/PhonePe","jobId":18611231}}
{"args":{"projectId":"PhonePe","jobId":18611231}}
```

`jobId` is still a positive integer or numeric string. Nested paths such as
`group/subgroup/project` are supported. Supply readable paths, not `%2F`-encoded
strings or full GitLab URLs. The plugin URL-encodes paths internally and never
takes a different host from a project reference.

## GitLab job URLs

Alternatively, supply exactly one `url` argument, as the **GitLab Install**
[browser panel](browser.md) does:

```json
{"args":{"url":"https://gitlab.example.com/group/project/-/jobs/456/artifacts/browse"}}
```

The plugin accepts job pages and artifact browse/download links on its configured
HTTPS host (default port or 443), including nested namespaces. Userinfo and other
hosts/ports are refused. Query strings and fragments are ignored, never used for
authentication; the existing host token is used. Do not mix `url` with ID arguments.
The project path is resolved and checked against the numeric allowlist as below.

## Resolution and authorization

- **Numeric ID:** use the existing direct download path; no project metadata
  lookup is added.
- **Full path:** query the configured GitLab host for that project and obtain
  its numeric identity before downloading.
- **Bare name:** search projects accessible to the host token, matching the
  complete display name or project slug case-insensitively, not a substring.
  Search pages are checked before accepting a single match. Zero exact matches
  fail; multiple distinct matches fail with candidate paths and IDs. Supply the
  desired full path rather than guessing or starting multiple installs.

The host's `projectIds` configuration remains a **numeric allowlist**. A resolved
path/name must pass the same check as an explicit ID; an allowlist is never used
to guess which ambiguous project the caller intended. `"*"` allows any resolved
project accessible to the token; `[]` disables downloads before lookup. Token
permissions must allow reading project metadata for path/name resolution.

References are bounded to 1,024 characters. Paths use slash-separated
alphanumeric/underscore-led segments with letters, digits, underscores, dots or
hyphens. Bare names allow letters, digits, underscores, spaces, dots and hyphens,
and must contain a letter or underscore;
surrounding whitespace, traversal, control characters, URLs and shell syntax are
rejected. All-numeric references mean IDs, not name searches.

## Progress and failures

Names and paths add a `resolving` phase before the existing download/extraction
phases. Each metadata request has a 30-second subprocess timeout and a 4 MiB
per-file output bound. Search is limited to 100 pages of 100 projects; exhausting
that limit fails closed rather than claiming uniqueness. Supply a full path or
numeric ID if a name cannot be resolved within the bound.

Lookup failures retain the command, HTTP/glab stderr, exit status, exception and
traceback excerpts under the existing redaction and 4 KiB status-message budget.
No project metadata body is dumped into diagnostics. See
[failure diagnostics](gitlab-diagnostics.md) and [start/poll/cancel](README.md#start-and-poll).

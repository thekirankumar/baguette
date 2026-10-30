---
description: Download an app from an HTTP(S) URL with optional per-call headers, extract a ZIP or hand an IPA directly to the simulator installer, and poll progress and detailed errors. Use for authenticated build links and signed download URLs.
---

# Install an app from a URL

`url-download:install` is a background plugin. It streams a download on the
server host, prepares the app, and hands it to baguette for installation and
workspace cleanup. It requires `python3`, not `curl`, `glab` or extra Python
packages. It contributes an install command and a [browser panel](../plugin-runs/browser.md).

## Configure and start

In `plugins/url-download/config.json`, set `allowedHosts` to the exact hostnames
used by your build service, including any redirect destinations:

```json
{
  "allowedHosts": ["builds.example.com", "downloads.example.com"],
  "allowHTTP": false,
  "maxArchiveBytes": 3221225472,
  "maxExpandedBytes": 17179869184,
  "maxEntries": 50000,
  "requestTimeoutSeconds": 30,
  "maxRedirects": 5
}
```

The shipped `allowedHosts: []` disables downloads until configured. Explicitly
setting `allowedHosts: "*"` allows any host; it is not the default. Plain HTTP
requires `allowHTTP: true`. Optional host-configured `appPath`, such as
`"build/MyApp.app"`, selects a particular app from a ZIP.

From the checkout, start the updated host with:

```bash
baguette serve --plugin-dir plugins
```

The plugin directory is independently installable; it does not depend on the
GitLab plugin being present. IPA handoff requires the updated host that accepts
`.ipa` background output, not an older `.app`-only host.

For browser use, focus a simulator, open **URL Install** in the plugin rail,
paste a direct download or signed URL, then click **Install**. The minimal
panel accepts only a URL; use the API/CLI below for per-call headers.

## URL and headers are invocation parameters

Both go inside `args`. `headers` is optional and maps header names to string
values; authorization is not read from host configuration or environment:

```json
{
  "args": {
    "url": "https://builds.example.com/job/123/MyApp.zip",
    "headers": {
      "Authorization": "Bearer <access-token>",
      "X-API-Key": "<api-key>"
    }
  }
}
```

For a signed URL, supply the whole URL, including its query string. For a public
download, omit `headers`. The only accepted arguments are `url` and `headers`;
timeouts, limits, allowed hosts and app selection remain host policy.

Send the above JSON from a private file over an authenticated, trusted connection:

```bash
BASE=http://127.0.0.1:8421
UDID='<UDID>'
curl -i -X POST "$BASE/plugins/url-download/commands/install/runs?udid=$UDID" \
  -H 'Content-Type: application/json' --data-binary @request.json
# 202 Accepted; follow the Location header, preserving a proxy mount prefix.
curl "$BASE/runs/<id>.json"
```

For a non-sensitive example, the CLI uses the same invocation shape:

```bash
baguette plugin start url-download:install --udid "$UDID" --url "$BASE" \
  --args '{"url":"https://builds.example.com/MyApp.ipa"}'
baguette plugin wait '<id>' --url "$BASE"
baguette plugin cancel '<id>' --url "$BASE"
```

Avoid putting real headers or signed URLs in shell history or process arguments.
`request.json` contains credentials: restrict its permissions and remove it when
no longer needed. General lifecycle/limits: [background runs](../plugin-runs/README.md).

## ZIP versus IPA

- **ZIP:** validate the directory, safely extract, preserve executable modes,
  and select exactly one outer `.app`, ignoring nested apps inside bundles.
  Zero or multiple candidates fail with details; configure `appPath` if needed.
- **IPA:** validate the archive directory and read entries to check CRC and
  actual expanded-byte limits, without writing extracted files. Hand the original
  `.ipa` directly to the host's normal installer. An IPA is itself a ZIP, so an
  explicit `.ipa` filename takes precedence over generic ZIP detection.
- Response `Content-Disposition` supplies a filename when available; otherwise
  the final URL supplies it. Extensionless links are inspected: a
  `Payload/<Name>.app/Info.plist` layout is treated as an IPA; other ZIPs use app
  extraction. Explicit `.zip` downloads stay ZIPs even with a `Payload` layout.
- Local filenames are fixed by the plugin, never taken from an untrusted
  response path. HTML login pages, corrupt archives and unsupported non-ZIP
  files fail rather than being passed to the installer.

**An iPhone-only IPA may fail on a simulator.** This plugin does not convert
device binaries into simulator builds. Installation uses the existing
[app installation path](../file-upload/README.md).

## Progress and failures

Poll `state`, `phase` and `downloadedBytes`. ZIPs pass through `downloading`,
`extracting`, `prepared`, then host-owned `installing`; IPAs use `validating`
instead of `extracting`. Available download bytes are reported without waiting
for a whole megabyte. Status HTTP `200` is not proof of success; inspect the
terminal `state`. Cancellation, preparation timeout and cleanup are host-owned.

Failures include HTTP status/reason and a bounded response-body excerpt,
network/TLS exceptions, downloaded bytes, configured limits, disk-space values,
offending archive paths or app candidates, chained causes and traceback excerpts.
All header values, known credential values and URL query values are redacted.
There is no full environment/request dump or binary artifact body in reports.
Redaction cannot identify every possible secret in arbitrary server output;
review messages before sharing them.

The unchanged host retains at most **4,096 UTF-8 bytes** per failure message.
Causes come first; oversized sections have explicit truncation notices.
Workspace files are deleted after success, failure or cancellation, so no full
download log remains. The plugin's standard output/error are not status channels.

## Security and limits

- Every redirect is checked against host policy and the redirect limit. All
  custom headers are dropped when the scheme, host or port changes; they stay
  dropped even if a later redirect returns to the original origin. An
  HTTPS-to-HTTP redirect is always refused.
- Header injection, URL userinfo, proxy headers and transport overrides such as
  `Host`, `Content-Length` and `Transfer-Encoding` are refused. No ambient proxy,
  cookie, `.netrc` or authentication configuration is used.
- Download size is checked both against `Content-Length` and while streaming.
  ZIP/IPA entry count, declared/actual expanded bytes, unsafe paths, symlinks,
  special entries and case/Unicode path collisions are checked before handoff.
  As with the GitLab plugin, `zipfile` loads central-directory metadata before
  the entry-count check; this is not a hard process-memory bound.
- Host approval is not an SSRF sandbox: approved hosts can resolve to private
  addresses, and ports are not restricted. Authenticate callers, choose narrow
  host lists and enforce network egress policy if callers are untrusted.
- Requests have a configurable socket timeout; the overall preparation deadline
  remains the host's one-hour default. Installation cannot be cancelled once
  the host has begun it. See [ownership and limits](../plugin-runs/README.md#ownership-and-limits).

See also: [plugin authoring](../plugins/authoring.md) ·
[background command CLI](../../commands.md#baguette-plugin-start).

# Install builds from the browser

Start the updated host with `baguette serve --plugin-dir plugins`, after configuring
the plugins you want to use:

- [GitLab setup](README.md#configure-the-gitlab-example) — host credentials and project policy.
- [URL download setup](../url-download/README.md#configure-and-start) — allowed download hosts.

Focus a booted simulator and open **GitLab Install** or **URL Install** in the
right-hand plugin rail. Paste a [GitLab job link](gitlab-projects.md#gitlab-job-urls)
or direct ZIP/IPA URL, respectively, and click **Install** (or press Enter).
The focused simulator is the target. Each plugin appears only when installed or
discovered through `--plugin-dir`; neither is bundled into the binary.

## Progress and status

The panel polls the existing background-run API once a second. It shows the run
ID, current state, preparation/install phase, downloaded bytes and failure message.
The bar is indeterminate while active: the API reports bytes, not a total size or
an installation percentage. Only terminal `succeeded` means completion; an HTTP
`200` or `phase: installing` does not. Generic non-install commands say **Succeeded**
without implying they installed an app.

The field and submit button are locked while work is active. Closing the panel
stops browser polling, not the server-owned job. Reopening it in the same page
resumes observation. Navigating away or reloading loses this page's run tracking;
keep the displayed run ID for [CLI/API status](README.md#start-and-poll).

A temporary polling failure retains the run and retries status, never starts a
second job. A lost, invalid or server-error start response is **unconfirmed**:
the job may have started, so the panel blocks resubmission. Check the host before
trying again. Explicit client-error refusals such as busy (`409`) allow a retry.

URL prompt history is disabled, including for signed URLs. The URL-only panel
does not collect headers or GitLab credentials. Use the existing URL-download
API/CLI for [per-call headers](../url-download/README.md#url-and-headers-are-invocation-parameters).
Host policy, download preparation, installation and cleanup remain unchanged.

These panels require the updated browser renderer as well as the updated plugin
manifests. Older renderers only support synchronous panels. When mounted through
a proxy, that proxy must authorize/forward the existing catalog, start and status
routes; this UI does not add SimMER lease routing or change its authorization.

Plugin authors: [declare a background prompt](../plugins/authoring.md#background-command-prompts).

---
description: Add plugins (an Expo reload button, an accessibility audit, a deep-link bar) to baguette serve's rail, installed from trusted git "bakeries" and held to declared capabilities. Use when installing, trusting or running plugins.
---

# Plugins & bakeries

Plugins add domain-specific affordances — an Expo reload button, an
accessibility audit, a deep-link bar — without touching baguette's core. A
plugin is a directory with a `baguette-plugin.json` manifest and a command
baguette runs as a **subprocess**; nothing it ships is ever loaded into
baguette's process or into the served page — it declares a panel, and
baguette draws it with host markup. Every flag:
[commands.md#baguette-plugin](../../commands.md#baguette-plugin) ·
[commands.md#baguette-bakery](../../commands.md#baguette-bakery).

Two things define the security model:

- **A plugin's command runs as a real program with your permissions.** It's
  `node bin/foo.js` or `python3 bin/foo.py`, spawned by baguette — the same
  trust you extend to anything you `brew install`.
- **Installing a plugin never runs its code.** Install only clones and copies
  files; there are no postinstall hooks. The command runs only when you
  *activate* it — its button in the rail, or `baguette plugin run`.

## Quick start

```bash
baguette bakery add tddworks/baguette           # trust a source, once
baguette plugin show deeplink                   # what it may do, before you install
baguette plugin install deeplink                # or: plugin install owner/repo/deeplink
baguette serve                                  # the plugin appears in focus mode's rail
```

baguette's own repo is the **official bakery**. Only `a11y` ships inside the
binary, so a fresh install has something in the rail. Everything else
baguette maintains — starting with [`deeplink`](../deep-links/README.md) — is
official, supported, and still something you choose to install. The rail's
length stays a count of what you asked for.

Writing your own? See [authoring.md](authoring.md).
Long-running work uses [background plugin runs](../plugin-runs/README.md), not the ten-second panel contract.

## Workflows

### Install and manage from the CLI

```bash
# trust a source (prompts unless --yes), then install from it
baguette bakery add tddworks/baguette-plugins
baguette plugin install a11y

# or do both at once, directly:
baguette plugin install tddworks/baguette-plugins/a11y

baguette bakery list                 # trusted sources + pinned commits
baguette bakery outdated             # ask each remote whether it has moved
baguette plugin list                 # installed plugins + provenance
baguette plugin update               # re-pull + re-install at latest
baguette plugin remove a11y
baguette bakery remove tddworks/baguette-plugins
```

References: `owner/repo` (GitHub), `owner/repo/plugin`, a full `https://…` /
`git@…` URL (any host), or `file://…` (a local checkout).

### Install from the browser

In focus mode, the plugins rail on the right has a **+** at the bottom.
It opens a modal in two halves, and the split is the trust boundary.

**The shelf** lists every bakery you already trust, its pinned commit, and
what it offers, with **Install** on what you don't have yet. Installing does
the same work as `baguette plugin install` (so the same minute on a cold
cache), then the rail picks the new plugin up without a reload.

**The field below only previews.** Paste `owner/repo`, click
**Preview**, and you see the source, its resolved commit, and what it
offers, followed by the `baguette bakery add` command to copy. Run
that in a terminal and the bakery joins the shelf.

The browser can install from a bakery you already trust, but trusting a *new*
source stays a terminal act — a modal button isn't real consent. Why:
[design.md](design.md#why-the-browser-can-install-but-not-trust).

### Keep up to date

`baguette bakery outdated` asks each trusted remote what it points at now (one
`ls-remote` each — no clone, no files touched) and reports which have moved:

```text
github.com/acme/tools   a1b2c3d → f9e8d7c  update available
github.com/other/pack   up to date  @9f8e7d6
```

It only *reports* — nothing changes until you run `bakery update`, since an
update that applied itself would defeat the pin. A remote it can't reach is
reported as unreachable, never as up to date.

### Run a plugin command without the page

```bash
baguette plugin run a11y:audit --udid <UDID>
```

It talks to a running `baguette serve` (`--url`). Commands are namespaced by
plugin, so two plugins can both ship a `reload`.

## The rail

Plugins live in their own strip on the right edge of focus mode, apart from
the device toolbar — baguette ships the toolbar, plugins are code you
installed, and the split is a trust signal. **One plugin is one slot, however
many tools it ships**: a single panel opens on click; several collapse to one
entry marked with a caret, whose flyout (hover, click or tab to it; `Esc`
closes) lists each tool by icon **and** name.

## Capabilities

A plugin may only do what its manifest declared, and `baguette plugin show
<name>` prints that list before you install. `capabilities` is a closed set,
**enforced** in front of every route: each invocation gets its own token
carrying exactly the declared set, revoked the moment the command exits, and
a call outside it answers `403`. A manifest that declares nothing gets
nothing, and routes no capability names — booting a device, orientation, the
camera source, installing another plugin — are closed to plugins entirely.
The full table of what each capability grants is in
[authoring.md](authoring.md#capabilities).

### What capabilities are not

They govern **the plugin API** — what a plugin can ask *baguette* to do in its
name. They are not a sandbox around the plugin's process: a plugin's command
is a real program running as you, and nothing stops it from running `curl`
against the same server, `baguette tap` directly, or reading your files. Read
the list as **a declaration of intent, enforced at the API boundary**. The
consent that actually protects you is the one you give when you trust the
bakery.

## Trust & storage

Trust is **per bakery, once**. Fetches are shallow, non-interactive (a bad
URL fails fast), and pull no submodules.

**The pin is a demand, not a note.** Adding a bakery records the commit
you saw; every install from it afterwards fetches *that commit by name*
rather than whatever the default branch points at today. Otherwise a
source accepted months ago would quietly deliver its current contents,
and the recorded sha would only ever describe what you happened to get.

If the bakery no longer serves the pinned commit — rewritten history, a
force-push — the install **fails** rather than falling back to HEAD.
Re-add the bakery to look at what it holds now and trust that instead.
Moving the pin forward deliberately is what `update` is for.

```text
~/.baguette/                          # or $BAGUETTE_HOME
  bakeries.json                       # trusted sources
  installed.json                      # which plugin came from which bakery@commit
  bakeries/<host>/<owner>/<repo>/     # clone cache
  plugins/<name>/                     # installed plugins (also the scan root)
```

## HTTP

| Route | Does |
|---|---|
| `GET /plugins.json` | Installed plugins and what they contribute (the rail's source) |
| `POST /plugins/:id/commands/:cmd?udid=<UDID>` | Run one plugin command; optional body `{"args":{…}}`; answers the command's JSON |
| `GET /bakeries.json` | Trusted bakeries, their pinned commits and menus |
| `POST /bakeries/preview` | `{"ref":"owner/repo"}` — clone and read a menu, recording nothing |
| `POST /bakeries/install` | Install one plugin from an already-trusted bakery |

```
POST /bakeries/install   {"bakery": "github.com/tddworks/baguette",
                          "plugin": "deeplink"}
  → 200 {"bakery": "…", "commit": "20fc40f19d…", "installed": ["deeplink"]}
  → 403 {"ok": false, "error": "that bakery isn't trusted — …"}
```

A plugin command answers `404` for an unknown command and `500` when it
failed. The routes a plugin's own command may call are its
[capabilities](authoring.md#capabilities).

## Gotchas

- **A command has ten seconds.** At the deadline it gets `SIGTERM`, and two
  seconds later `SIGKILL`.
- **A panel doesn't re-run per keystroke.** Typing filters the rows the
  command already returned; the command only runs again on submit.
- **`--no-plugins`** on `baguette serve` ignores every installed plugin,
  including the bundled `a11y`; `--plugin-dir` shadows an installed plugin of
  the same name.

## See also

- [authoring.md](authoring.md) — the manifest, the command contract, panels, bakery menus
- [design.md](design.md) — why the browser can install but not trust, per-invocation tokens, why ticks aren't glyphs
- [deep-links](../deep-links/README.md) — the `deeplink` plugin
- [interface](../interface/README.md) — the a11y plugin's Display & Text Size panel
- [`examples/expo-bakery/`](../../../examples/expo-bakery/) — a worked two-plugin bakery

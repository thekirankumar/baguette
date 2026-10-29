---
description: How baguette's docs are layered (Skill-style progressive disclosure), where each kind of content lives, and the limits CI checks. Read before adding or restructuring any doc.
---

# Documentation Design

> Status: **adopted**, 2026-09-24. CI fails when `scripts/check-docs.py --strict` reports a problem or a generated doc is stale.
> Adapted from asc-cli's documentation design; the differences are called out in [Decisions](#decisions).

## Goal

**Reduce accidental complexity so docs are easy to change.**

Every other rule here follows from that goal. Each fact has exactly one home, so a code change touches at most one doc. When choosing between two options, pick the one where *the next change touches fewer places*.

## Problem

| File | Today | Accidental complexity |
|---|---|---|
| `README.md` | 972 lines | CLI reference (~150 lines), wire protocol (~110), source layout (~190), testing and "why this works" repeat `docs/features/*`, `docs/ARCHITECTURE.md`, the skill's references and the source tree |
| `CHANGELOG.md` | 1,295 lines, 43 releases | Bullets average ~830 chars (longest 3,634); 108 of 130 are over 300. They name internal types, private symbols and file paths, which repeats the PR |
| `docs/features/*.md` | 32 files, ~9.4k lines | 18 are over 200 lines. Usage, wire JSON, dispatch paths and reverse-engineering notes share one file, so users wade through HID constants and contributors can't find the research |
| `CLAUDE.md` | 133 lines, loaded every session | Line count hides the size: each "Known iOS 26 limits" bullet is a full write-up (the HID-target one is ~2,000 chars) that also lives, in longer form, in its feature doc |
| `AGENTS.md` | 135 lines | A hand copy of `CLAUDE.md` for other agents, already drifted: missing the Device Hub limit and the JS-testing rules |
| `skills/baguette/references/` | `cli.md`, `wire-protocol.md` | Hand-copied from the README; a flag change means three edits |
| Links | 0 broken | Nothing checks them, so that's luck |

**Root cause:** every feature copies the same facts into several places (README CLI list + README section + feature doc + skill reference + long changelog bullet + AGENTS.md limit). Copies are synced by hand and nothing checks that they are.

## Principle: docs load like Skills

Agent Skills stay cheap by loading content in three tiers, where each tier only *points* to the next:

| Skill tier | Loaded | baguette docs equivalent |
|---|---|---|
| **1. Metadata** (`name` + `description`) | Always | `README.md`, `AGENTS.md`, the `docs/README.md` index, CHANGELOG lines |
| **2. Instructions** (`SKILL.md` body) | When needed | `docs/features/<x>/README.md`: how to use one feature |
| **3. Resources** (`references/`, `scripts/`) | On demand, by link | `docs/features/<x>/design.md` and topic files, generated `docs/commands.md`, `docs/wire.md` |

Rules:

1. **One home per fact; tiers link, they don't copy.** Any copy is a future inconsistency.
2. **Don't write what code or `--help` already says.** Flags, file trees and type lists are read from the source. A doc can't go stale about something it doesn't contain.
3. **Do write what the code can't say.** baguette leans on private SimulatorKit / CoreSimulator / HID behaviour. *Why* a signature, target or ordering is what it is was found by experiment, and is lost if it isn't written down. That research has a home too: the feature's `design.md`.
4. **Same shape everywhere; nothing empty.** Every feature gets the same folder shape, but no empty subfolders and no metadata fields that nothing reads.

## Layout

```
README.md                       tier 1: pitch, demo, install, quick start, feature table → links
AGENTS.md                       tier 1: agent rules only (TDD gate, layers, one-line limits → links)
CONTRIBUTING.md                 tier 1: build, test, where things go → links
CHANGELOG.md                    tier 1: [Unreleased] + current minor only, one line per change → links
docs/
├── README.md                   tier 1: index, GENERATED from feature descriptions
├── documentation-design/       this design (README.md) + layout.md
├── ARCHITECTURE.md             tap-to-UITouch flow, layers, route table (unchanged; the one diagram home)
├── CANONICAL_MODEL.md          the domain tree, its words, every law and its one owner, the contexts
├── commands.md                 tier 3: GENERATED from swift-argument-parser, never hand-edited
├── wire.md                     tier 3: `baguette input` + WebSocket JSON (moved from README)
├── serve.md                    tier 3: `baguette serve` routes (moved from README)
├── changelog/                  tier 3: one file per past minor, moved as-is, never edited
│   └── 0.1.md
└── features/                   one folder per feature, shaped like a Skill
    ├── shake/
    │   └── README.md           tier 2: description + user guide (≤200 lines); most features stop here
    └── iphone-duo/
        ├── README.md           tier 2
        ├── design.md           tier 3: why it works this way — private API, measured constants, dead ends
        └── assets/             only if the feature has images
```

Outside this design and left alone: the website (`docs/index.html`, `home2.html`, `architecture.html`), `docs/mockups/`, `docs/prototypes/` and `docs/announcements/`. They are pages, not docs, and `check-docs` skips them. GitHub Pages serves `docs/` from `main` and `index.html` wins over the generated `docs/README.md`, so the site is unaffected; the site's one link into the docs, `./ARCHITECTURE.md`, keeps its path.

File-by-file detail, written from the reader's side with a mockup of each file: [layout.md](layout.md).

Every feature is a folder with a `README.md`, the same way every skill is a folder with a `SKILL.md`:

- **One predictable path.** A feature's docs are always at `docs/features/<x>/`. Readers and agents never check whether a feature is a file, a folder or both.
- **Growing never moves anything.** Research becomes `design.md`, a deep dive becomes `<topic>.md`, both next to `README.md`. The feature's path and links stay the same.
- **GitHub shows it on open.** Browsing `docs/features/shake/` renders the README.

## Tier 1: metadata

### Frontmatter: one field

```yaml
---
description: Deliver a motion shake to a booted simulator, like Simulator.app's Device → Shake. Use when testing shake-to-undo or a shake-to-report menu.
---
```

- `description` works like a Skill's: one sentence saying *what* and *when*, ≤250 chars.
- No `name` field; the folder name is the name. No other fields until something reads them.
- `make docs` builds `docs/README.md` from these lines. Adding a feature means writing one file.

### README.md (≤150 lines)

Keeps: logo/badges, one-paragraph pitch, the demo, install (+ troubleshooting pointer), a quick start, the feature table (each row links to its feature doc), links to docs index / contributing / changelog, license.

| Section today | New home |
|---|---|
| CLI (~150 lines) | Removed; `docs/commands.md` is generated |
| Capture size | `docs/features/capture-size/README.md` |
| `baguette serve` routes + WebSocket | `docs/serve.md` |
| Device farm | `docs/features/device-farm/README.md` |
| Plugins & bakeries | `docs/features/plugins/README.md` |
| Wire protocol — `baguette input` | `docs/wire.md` |
| `baguette stream` / `baguette chrome` | `docs/commands.md` + their feature docs |
| Source layout (~190 lines) | Deleted; the tree is `ls Sources/`, the layering rule is in `docs/ARCHITECTURE.md` |
| Testing | `CONTRIBUTING.md` |
| Why this works on iOS 26.4 | `docs/ARCHITECTURE.md` |
| Build from source | `CONTRIBUTING.md` |

### AGENTS.md (≤100 lines, ≤12k chars)

The one agent-instructions file. There is no `CLAUDE.md`: Claude Code reads `AGENTS.md` natively when a project has no `CLAUDE.md` (v2.1.277+), and two files were already drifting apart.


Keeps: the TDD gate, the naming rules, build/test commands, the three-layer rule, and **one line per known limit** with a link.

- **Known limits shrink to one line each**, e.g. "Duo hardware keys don't take Indigo presses; buttons route through `dtuhidd` → `docs/features/iphone-duo/design.md`". The line keeps the warning an agent needs on every task; the research moves to the feature's `design.md`, its one home.
- **Moves to the `baguette-implement-feature` skill** (loaded only while building a feature): extensibility hot spots, JS testing conventions, doc-update rules.
- **Budget in characters too.** A line budget alone lets a 2,000-char line through.

### CHANGELOG.md

Answers the upgrader's questions in order: *will this break me → is my bug fixed → what's new*. Going forward:

- `Removed` / `Changed` come before `Added`; anything incompatible starts with `Breaking:` and says what to use instead.
- Each bullet starts with what the user types (`` `baguette tap` ``, `` `POST /simulators/:udid/hinge` ``, a page control), says the effect rather than the implementation, and is ≤300 chars. Related fixes are merged.
- Links point only to files that already exist:

  | Link | Points to | Reader gets | When |
  |---|---|---|---|
  | `→ [docs](docs/features/<x>/README.md#<section>)` | The feature doc | How to use it now | `Added`, `Changed`, `Breaking`, or a fix with a gotcha |
  | `([#123](https://github.com/tddworks/baguette/pull/123))` | The PR | Why and how: symbols, private API, tests | Every bullet |

  URLs don't count toward the 300 chars.
- Private symbols, HID constants, type names and file paths go in the PR and the feature's `design.md`, never in the bullet.
- When a contributor adds no entry, the release workflow inserts GitHub's generated notes (PR title + author). That stays; it is already one line per change.

Real before → after rewrites are in [layout.md](layout.md#changelogmd).

#### Size: the current minor stays, older minors roll off

- `CHANGELOG.md` holds `[Unreleased]` plus the **current minor** (today 0.2.x), then an "Older releases" line linking each `docs/changelog/<minor>.md`.
- **When a new minor is released**, the previous minor's sections move unchanged into `docs/changelog/<minor>.md` with their compare links. `scripts/changelog-rollover.py`, run by `scripts/promote-changelog.sh` in the release workflow, does it; `scripts/test-changelog-release.sh` covers patch and minor releases with and without entries.
- **Archived sections are moved, never rewritten.**

The initial split turns 1,295 lines into ~30 in `CHANGELOG.md`, with `docs/changelog/0.1.md` holding 0.1.4 → 0.1.99.

## Tier 2: feature doc (≤200 lines)

Written for someone *using* the feature, human or agent. It contains only what `--help` and the code can't say:

1. **Title + one-line summary**
2. **Quick start**: the 2–4 commands of the happy path (CLI, and the page control if there is one)
3. **Workflows**: end-to-end scripts for common jobs
4. **HTTP / WebSocket**: the feature's own routes and messages, one example each. Gestures link to `docs/wire.md` instead of repeating it
5. **Gotchas**: what will bite a user — iOS / Xcode version limits, "only apps launched after arming see it", "needs the sim booted"
6. **See also**: `docs/commands.md#<cmd>`, `design.md`, related features

No flag tables (generated), no file maps, no type lists, no test snippets, no "Extension points" stubs.

## Tier 3: resources

- **`docs/features/<x>/design.md`**: contributor-facing research for one feature. Why the private call is shaped this way, the constants and where they were measured, the ordering that matters, what was tried and failed. This is the home of today's "Why", "Dispatch path", "Where the (page, usage) numbers come from" and the long AGENTS.md limits. Only features with such research have one.
- **`docs/features/<x>/<topic>.md`**: user-facing deep dives too long for the README (e.g. recording presets).
- **`docs/commands.md`**: generated by `make docs` from `baguette --experimental-dump-help`. The only complete flag list; the skill links to it.
- **`docs/wire.md`**: the gesture wire shared by `baguette input` (stdin) and the stream WebSocket — gesture envelopes, stream-control messages, acks, coordinates. **`docs/serve.md`**: the route table of `baguette serve`, one row per route linking to the feature that owns it. A feature's *own* routes and messages (camera, logs, hinge, location…) live in that feature's README, their one home; `wire.md` and `serve.md` link to them rather than repeat them.
- **Deleted, not moved**: file maps, source trees, type lists, test listings. The code is their one home.

## Reader paths

| Reader | Path |
|---|---|
| New user | README → quick start |
| Feature user | README table / `docs/README.md` → feature doc |
| Needs every flag | feature doc → `docs/commands.md` or `baguette <cmd> --help` |
| Host plugin author | `docs/wire.md` |
| Agent driving a sim | `baguette` skill → feature doc → `docs/commands.md` |
| Contributor | CONTRIBUTING → `docs/ARCHITECTURE.md` → feature `design.md` → code |
| Agent building a feature | AGENTS.md → `baguette-implement-feature` skill → feature `design.md` |

## Update rules

| Change | Touch | Nothing else |
|---|---|---|
| New feature | `docs/features/<x>/README.md` with a `description`, one CHANGELOG line, `make docs` | README only if it's a new feature-table row |
| New or changed flag | Nothing; `make docs` regenerates `commands.md` | |
| New wire message or route | `docs/wire.md` or `docs/serve.md` section, one CHANGELOG line | |
| Private-API finding | The feature's `design.md`; a one-line AGENTS.md limit only if agents must know it on every task | |
| Bug fix | One CHANGELOG line; a Gotchas entry if users could hit it again | |

Skills follow the same rule: `skills/baguette` carries the agent workflow. Because it is installed on its own, outside this repo, `make docs` copies `docs/commands.md` and `docs/wire.md` into its `references/` with absolute links; those copies are generated, never edited, and CI fails when they're stale.

## Enforcement

`scripts/check-docs.py` in CI (`--strict` fails the build). Kept small, because it is code that also has to be maintained.

| Check | Limit |
|---|---|
| Line budgets | README ≤150, AGENTS.md ≤100, `docs/features/*/README.md` ≤200 |
| Char budget | AGENTS.md ≤12,000 |
| CHANGELOG bullet length in `[Unreleased]` | ≤300 chars, URLs excluded |
| `CHANGELOG.md` holds only `[Unreleased]` + one minor | fails once a second minor appears (rollover forgotten) |
| Every feature doc has a `description` | required, ≤250 chars |
| Relative links resolve (code fences and inline code skipped) | all `.md` files |
| Generated files are current | `gen-docs.py` on the CI build, then `git diff --exit-code` |

When a doc goes over budget, split it. Don't raise the limit.

## Migration

Each step is its own commit in one PR, and the docs stay valid after each one.

1. **Hygiene**: this design; split `CHANGELOG.md` into 0.2.x + `docs/changelog/0.1.md`; changelog rollover in the release workflow; `scripts/check-docs.py` in report-only mode.
2. **Generation**: `make docs` builds `docs/commands.md` and `docs/README.md`.
3. **Move**: `git mv docs/features/<x>.md docs/features/<x>/README.md` for all 32 features; a script rewrites links (including the skills, AGENTS.md and source comments) and `check-docs.py` proves none broke. Mechanical, no content changes. Done before tier 1 so the new README links to final paths.
4. **Tier 1**: slim README; add `CONTRIBUTING.md`, `docs/wire.md`, `docs/serve.md`.
5. **Split**: per feature, add `description`, move research sections into `design.md`, keep usage + gotchas in `README.md`, delete file maps and flag tables. Parallelisable per feature.
6. **AGENTS.md + skills**: limits to one line each; checklists into `baguette-implement-feature`; `skills/baguette/references/` link instead of copy.
7. **Enforce**: turn `check-docs.py --strict` on in CI.

## Decisions

Each one is judged by the goal: *does the next change touch fewer places?*

| Question | Decision | Why |
|---|---|---|
| Research sections (Why, Dispatch path, HID constants) | **Move to `design.md`**, don't delete | Unlike asc-cli's internals, they don't restate the code; they record experiments against private frameworks that the code can't explain and nobody wants to redo |
| File maps, source tree, type lists | **Delete** | They copy the code, so every refactor would need a doc edit nobody makes |
| Flag tables | **Delete; generate `docs/commands.md`** | Flags change with the code; generated means zero manual edits |
| Wire protocol | **One hand-written `docs/wire.md`** | It's a contract with host plugins, not derivable from `--help`; today it lives in README, the skill and feature docs |
| AGENTS.md limits | **One line each + link** | The warning is needed every session; the explanation is needed only when touching that feature |
| Old CHANGELOG entries | **Keep the wording; new style going forward** | Rewriting history is work with no gain |
| One CHANGELOG file vs rolling archive | **Current minor in `CHANGELOG.md`, older minors in `docs/changelog/<minor>.md`** | Tier 1 stays small; one scripted move per minor; CI catches a forgotten rollover |
| Folder per feature vs flat file | **Folder per feature, `README.md` inside** | One path forever; `design.md` has an obvious place to live |
| Frontmatter fields | **`description` only** | Every extra field has to be kept correct |
| `CLAUDE.md` vs `AGENTS.md` | **`AGENTS.md` only** | Every agent reads it, Claude Code included (v2.1.277+). The old two-file setup had drifted within a month. Older Claude Code, or Bedrock / Vertex / Foundry sessions without native support, can add a local `CLAUDE.md` containing `@AGENTS.md` |
| Hand-written vs generated index | **Generated** | Adding a feature touches one file instead of two |
| Website HTML under `docs/` | **Out of scope** | Pages, not docs; moving them would break the published site for no gain here |

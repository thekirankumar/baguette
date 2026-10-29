# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

---

## [0.2.12] - 2026-10-29

### Fixed
- `POST /simulators/:udid/hinge` and the 3D socket's `set_pose` fold iPhone Duo's live 3D book at 60 Hz, then settle on the hinge's reading, instead of moving only as fast as the guest's readings came back (~9/s on a loaded host). → [docs](docs/features/hinge/README.md#http--websocket) ([#128](https://github.com/tddworks/baguette/pull/128))
- `baguette hinge --duration`, `POST /simulators/:udid/hinge` and `set_pose` reject a sweep longer than 60 s, instead of a huge one stopping `serve`. A refused `set_pose` names what was wrong, not `invalid 3D camera`. → [docs](docs/features/hinge/README.md#http--websocket) ([#128](https://github.com/tddworks/baguette/pull/128))

---

## [0.2.11] - 2026-10-26

### Added
- `baguette press --button software-keyboard` toggles the on-screen keyboard for a focused text field. The same button name works over stdin and WebSocket. → [docs](docs/features/keyboard/README.md#software-keyboard) ([#127](https://github.com/tddworks/baguette/pull/127))

---

## [0.2.10] - 2026-10-21

### Changed
* docs(skill): route the baguette skill by what the agent is doing by @hanrw in https://github.com/tddworks/baguette/pull/125
* docs(domain): canonical model + a domain-first step in the feature skill by @hanrw in https://github.com/tddworks/baguette/pull/126
* fix(duo): tap, drag and type on whichever panel is lit by @hanrw in https://github.com/tddworks/baguette/pull/124

---

## [0.2.9] - 2026-10-21

### Fixed
- iPhone Duo types: `type`, `key` and the page's keyboard press keys through the guest, as its hardware keys already do, instead of a keyboard message the Duo drops on either panel. → [docs](docs/features/iphone-duo/README.md)
- On iPhone Duo's page, taps, drags and typing follow the lit panel after a fold instead of landing on the panel that went dark; a drag stays on the panel it started on. → [docs](docs/features/iphone-duo/README.md)
- `--device-set` now reaches every `simctl` call, so shake, status bar, location, appearance, clipboard, logs, apps, deep links, `notify`, photos, defaults, motion, network, camera and `heal` work on a device in a custom set instead of failing with `Invalid device`. ([#122](https://github.com/tddworks/baguette/pull/122))
- `serve`'s live 3D stream (`/simulators/:udid/stream.3d.avcc` and `.mjpeg`) frees its memory when the socket closes and loads each device model once, so `serve` no longer grows with every connection (by up to 30 MB for iPhone Duo). → [docs](docs/features/3d-rendering/design.md) ([#123](https://github.com/tddworks/baguette/pull/123))

---

## [0.2.8] - 2026-10-20

### Added
- `baguette notify` and the serve toolbar's bell card deliver a remote notification payload to an app, as if APNs sent it, and say what to expect (a banner needs authorization and a backgrounded app). → [docs](docs/features/notifications/README.md) ([#120](https://github.com/tddworks/baguette/pull/120))

### Fixed
- `baguette hinge` and `GET /simulators/:udid/hinge` read iPhone Duo's hinge again on Xcode 27.1's release build, in a custom `--device-set` and right after a fold, so streams, screenshots, taps, `describe-ui` and hinge messages follow the lit panel. → [docs](docs/features/hinge/README.md#gotchas)

---

## [0.2.7] - 2026-10-15

### Added
- `baguette defaults read` and the Defaults card now list the settings a running app reads but hasn't stored yet (`@AppStorage` defaults, `register(defaults:)`), typed, so you can set them on a fresh install. → [docs](docs/features/defaults/README.md#workflows) ([#116](https://github.com/tddworks/baguette/pull/116))
- `defaults … --relaunch-if-needed` and the Defaults card change an `@AppStorage` setting in the running app at once, relaunching only for keys it read once; the card also filters by key or type and flashes values the app writes. → [docs](docs/features/defaults/README.md#live-or-relaunch) ([#116](https://github.com/tddworks/baguette/pull/116))

### Fixed
- `serve`'s floating panels (Defaults, Status bar, Network, …) no longer slide under the toolbar in a window taller than the device needs. ([#116](https://github.com/tddworks/baguette/pull/116))

---

## [0.2.6] - 2026-10-13

### Added
- `baguette defaults read|write|delete|export|import` reads, edits and restores an app's persisted UserDefaults or an App Group suite, typed; `--relaunch` quits and relaunches the app so it sees the change. Also a Defaults card in `serve`. → [docs](docs/features/defaults/README.md) ([#115](https://github.com/tddworks/baguette/pull/115))

---

## [0.2.5] - 2026-10-12

### Added
- `serve`'s ⛶ Handheld button (or `?handheld=1`) gives a phone the whole live screen — no bezel or toolbar, screen kept awake, a floating button for Home / Rotate / Exit; fullscreen on Android, via Add to Home Screen on iPhone. → [docs](docs/features/handheld/README.md) ([#114](https://github.com/tddworks/baguette/pull/114))

---

## [0.2.4] - 2026-10-07

## Older releases

[0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md) · [Fork 0.0](docs/changelog/0.0.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.2.12...HEAD
[0.2.12]: https://github.com/tddworks/baguette/compare/v0.2.11...v0.2.12
[0.2.11]: https://github.com/tddworks/baguette/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/tddworks/baguette/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/tddworks/baguette/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/tddworks/baguette/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/tddworks/baguette/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/tddworks/baguette/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/tddworks/baguette/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/tddworks/baguette/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/tddworks/baguette/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/tddworks/baguette/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/tddworks/baguette/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tddworks/baguette/compare/v0.1.99...v0.2.0

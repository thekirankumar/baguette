# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

---

## [0.0.2] - 2026-10-10

### Added
- `baguette plugin start/status/wait/cancel` manages background work, including GitLab artifact preparation and simulator installation, with polled outcomes after workspace cleanup. See [background runs](docs/features/plugin-runs/README.md).
- `baguette serve --rootpath /subpath` mounts HTTP and WebSocket routes beneath a prefix for local proxy-path testing, including redirects and plugin calls. The default `/` preserves existing URLs. See [proxy setup](docs/serve.md#proxy-subpaths).
- `baguette serve` works behind a proxy subpath without frontend configuration: assets, requests, device navigation and WebSockets retain the mount prefix. See [proxy setup](docs/serve.md#proxy-subpaths).

---

## [0.0.1] - 2026-10-10

## Older releases

[0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/tddworks/baguette/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/tddworks/baguette/compare/v0.2.4...v0.0.1

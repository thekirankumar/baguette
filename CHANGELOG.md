# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added
- `baguette serve --rootpath /subpath` mounts HTTP and WebSocket routes beneath a prefix for local proxy-path testing, including redirects and plugin calls. The default `/` preserves existing URLs. See [proxy setup](docs/serve.md#proxy-subpaths).
- `baguette serve` works behind a proxy subpath without frontend configuration: assets, requests, device navigation and WebSockets retain the mount prefix. See [proxy setup](docs/serve.md#proxy-subpaths).

---

## [0.0.1] - 2026-10-10


## Older releases

[0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/tddworks/baguette/compare/v0.2.4...v0.0.1

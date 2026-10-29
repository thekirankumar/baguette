# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Fixed
- `gitlab-artifacts:install` reports missing `glab`, GitLab stderr, exit status, preparation errors and traceback excerpts instead of generic failures, with credential redaction and explicit truncation within the existing status limit. → [docs](docs/features/plugin-runs/gitlab-diagnostics.md)

### Added
- `gitlab-artifacts:install` accepts project IDs, namespace/project paths and unique exact names, resolving names/paths before numeric allowlist checks and reporting ambiguous candidates. → [docs](docs/features/plugin-runs/gitlab-projects.md)
- `url-download:install` downloads from approved URLs with per-call headers, extracts ZIP apps or hands IPAs directly to the installer, with progress, cancellation and redacted diagnostics. Background app output now accepts regular IPA files. → [docs](docs/features/url-download/README.md)

---

## [0.0.4] - 2026-10-29


## Older releases

[0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md) · [0.0](docs/changelog/0.0.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.0.4...HEAD
[0.0.4]: https://github.com/tddworks/baguette/compare/v0.2.12...v0.0.4

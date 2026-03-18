# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.1.0] - 2026-03-17

### Added

- Initial release.
- `start`, `stop`, `status`, `logs`, `cleanup` commands.
- Cloudflare Tunnel creation with DNS CNAME routing.
- Generic server auto-detection (any TCP-listening process in the project directory).
- Auto-restart watchdog for tunnel process recovery.
- Quick tunnel mode (`--no-domain`) using `*.trycloudflare.com` URLs.
- `cloudflared` auto-installation prompt.
- Config caching in `.tunnel/`.
- CI pipeline with ShellCheck linting on pull requests.
- Automated npm publish and GitHub release on version bump.
- Release script (`scripts/release.sh`) for version management.

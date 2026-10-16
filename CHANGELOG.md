# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.1.0 (2026-10-16)

### Added

- NX-OS configuration/runtime parsers, profiles, observations, and host-independent collection.
- Standalone RubyGems packaging under `vxlan` with the `vxlan` require path and `Vxlan` namespace.
- English and Chinese documentation, an offline example, and standalone RSpec/RuboCop development tasks.
- Linux/macOS CI, isolated package verification, and automatic RubyGems and GitHub Releases with identical artifacts.

### Fixed

- Treat inline pagination as incomplete configuration before inferring absent VXLAN features.

### Changed

- Cross-module dependencies resolve through RubyGems/Bundler instead of relative sibling paths.
- Motor persistence and application-specific adapters remain in the host application.

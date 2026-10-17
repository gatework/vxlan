# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.2.0 (2026-10-17)

### Changed

- Breaking: replace `L2routeParser` with `RuntimeParser`, rename `CiscoNxos::ConfigurationDocument` to `CiscoNxos::Document`, and move configuration helpers from `ConfigurationParsing` to `Syntax`.
- Breaking: rename `CiscoNxos::Profile::CATALOG` to `DECLARATIONS` and adopt the shared `CtxParser::Configuration`, `Commands`, and address conversion APIs.
- Require symbol observation names and matching `Observation` values in snapshot dimensions; string interpolation now exposes metadata only.

### Fixed

- Copy collection identity and dimension selection before connector callbacks can mutate them.
- Reject paginated or terminal-edited runtime output with no records, and keep affected configuration captures incomplete.
- Exclude conflicting port-channel members across wrapped lines and groups, and stop continuations at invalid rows or table boundaries.
- Exclude conflicting singleton configuration values and prevent inheritance or default values from restoring ambiguous derived facts.
- Keep unsupported routing nesting partial and process deeply nested unrelated configuration without exhausting the Ruby call stack.
- Reduce repeated scans and copies in BGP statistics, policy sequence checks, prefix-list references, and wrapped L2RIB next hops while preserving ordering and duplicate rejection.

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

# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.2.2 (2026-10-18)

### Changed

- Name mutable NX-OS parsing state `CiscoNxos::ConfigurationState`; retain the former `Configuration` constant, require path, and `finish` method as compatible aliases.
- Clarify internal method names for conflict exclusion, diagnostics, address conversion, route-map consumers, and observation collection without changing parsed record fields.

### Fixed

- Exclude repeated prefix-list and route-map sequence identities, including malformed payloads, without restoring them later; preserve independent entries and capture their final array paths.
- Validate routing leaf ownership, supported address families, network prefix families, and IPv4 router IDs before accepting facts or projecting policy consumers.
- Exclude repeated hostname, BGP process, NVE interface, and vPC domain identities without restoring them on later declarations; invalidate their original source captures.
- Stop configured neighbor and policy projections through unsupported peer-template inheritance chains.
- Reject bare carriage returns in runtime output while preserving CRLF and existing configuration newline handling.
- Scan inline EVPN next hops by byte offset to avoid repeated copies of the remaining line.
- Report explicit EVPN/NVE layer mismatches and L3 NVE members without a matching configured VRF, independently of syntax completeness; retain valid VLAN-backed L3 VNIs.

## 0.2.1 (2026-10-17)

- Require ctx_parser and ctx_driver 0.2.x so configuration APIs and command capture behavior resolve consistently.

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

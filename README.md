# vxlan

[简体中文](README-zh.md) | [Source](https://github.com/gatework/vxlan) | [Changelog](CHANGELOG.md)

Cisco NX-OS VXLAN/EVPN configuration and operational observations in pure Ruby. Command-specific parsers preserve evidence completeness and relationships needed by inventory or review tools.

## Features

- Configuration facts for interfaces, VRFs, VLAN/VNI mappings, NVE, BGP, policies, and prefix lists.
- Runtime observations for CDP, NVE peers/VNIs, BGP EVPN, OSPF, vPC, interfaces, port channels, MAC tables, and L2RIB.
- Platform/model profiles and shared parsing infrastructure.
- Independent command collection and safe snapshots for host-owned persistence.

## Installation

Requires **Ruby 4.0.6 or newer**. Add this line to your application's `Gemfile`:

```ruby
gem "vxlan"
```

Then run `bundle install`, or install directly with `gem install vxlan`. The require path is `vxlan` and the public namespace is `Vxlan`; package names and Ruby namespaces are intentionally separate.

Internal runtime dependencies: [`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver). Shared Gatework dependencies require the compatible 0.2.x API. Applications should commit their own `Gemfile.lock` to make deployments reproducible. No Rails boot or sibling checkout paths are required.

Release artifacts and checksums are available from [GitHub Releases](https://github.com/gatework/vxlan/releases). Check [RubyGems](https://rubygems.org/gems/vxlan) for published versions.

## Offline example

From a development checkout after installing dependencies:

```sh
bundle exec ruby examples/offline.rb
```

The example uses synthetic data and performs no network access:

```ruby
require "vxlan"

# 使用合成 NX-OS OSPF 回显；文档地址不作为实时目标。
output = <<~CLI
  OSPF Process ID UNDERLAY VRF default
  Total number of neighbors: 1
  Neighbor ID Pri State Up Time Address Interface
  192.0.2.2 1 FULL/ - 1d 192.0.2.3 Eth1/1
CLI
observation = Vxlan::RuntimeParser.new.parse(:ospf_neighbors, output, complete: true)
puts "OSPF parse status: #{observation.status}"
puts "Neighbors: #{observation.records.size}"
observation.records.each { |record| p record }
# 单个已解析邻居仅是一项观测，不能证明整个 Fabric 健康。
```

## Command line

The gem installs `vxlan`; its implementation lives in `lib/vxlan/cli/`. The scripts in `examples/` are thin callers of the same implementation, plus a self-contained offline demonstration.

```sh
gem install vxlan
# Optional dependencies for live collection and .env files:
gem install net-connector -v '~> 0.14.1'
gem install dotenv -v '~> 3.0'
vxlan --help
vxlan collect --init --non-interactive
vxlan collect --inventory-only
vxlan parse --file running.cfg --complete
```

The installed command uses `vxlan.yml`, `.env`, and `vxlans/` in the invocation directory. Relative YAML paths resolve beside the config file; explicit CLI and process environment paths resolve from the invocation directory. Source examples retain their project-relative defaults. Initialization preserves existing files. Templates have one source under `lib/vxlan/cli/templates/`. Offline parsing and help do not load the connector. See [the CLI guide](bin/README.md) for configuration, filtering, reports, and exit codes.

## Public contract and limits

`Configuration.new.parse(text, complete: false)` returns a configuration observation. `RuntimeParser.new(platform: :cisco_nxos, model: nil).parse(name, text, complete: false)` returns a named runtime observation. `ParserRegistry.fetch(platform, model:)` exposes a declared profile for command-specific parsing.

Complete transport is necessary but insufficient for complete parsing: unknown syntax, conflicting identities, incomplete references, and ambiguous empty tables retain diagnostics. Configuration association findings are separate from syntax completeness and runtime health. IPv6 prefix-list facts do not imply IPv6 underlay inventory support.

`Collector#collect(connector:, target:, fabric_key:, model: nil, dimensions:)` uses a host-supplied connector; device identity, credentials, persistence, reconciliation, and concurrency policy belong to the host. This gem includes no fabric planner, provisioning engine, Rails models, or `Vxlan::Sync`. Loading or running the offline example does not access a device.

`Collector#collect_session(session:, target:, fabric_key:, platform: :cisco_nxos, model: nil, dimensions:)` borrows an already opened driver session (including the optional native adapter) without opening, closing, escalating privilege or retrying it. When configuration is selected, it is read before dimensions that depend on it; result order still matches the requested dimensions.

The collector copies target identity, fabric identity, and dimension selection before opening the connection. `Observation` names must be symbols; each `Snapshot` dimension must hold an `Observation` with a matching name. Both objects use their metadata-only `inspect` representation for string interpolation.

Conflicting singleton configuration values are excluded and reported as partial evidence, including interface, NVE, routing, VRF, and vPC settings. An interface with a conflicting VRF, or a BGP neighbor or template with conflicting settings, is excluded before deriving addresses or inherited facts; unresolved peer templates produce no neighbor projection. Unsupported routing nesting stays partial. Runtime output containing pagination or terminal editing controls returns `partial` with no records because its row boundaries cannot be trusted. Port-channel member conflicts are excluded across both wrapped lines and separate groups.

Detailed vendor behavior, historical validation notes, and Motor-only integration are preserved in [the architecture reference](docs/architecture-zh.md). Host integration examples in that reference require Motor; they are not standalone gem APIs. Motor adapters live under `backend/lib/baseline`, `backend/lib/vxlan`, and `backend/lib/wireless` in the [Motor repository](https://github.com/gatework/motor/tree/main/backend/lib).

The lifecycle connector is a host adapter exposing `open { |session| }` (and `platform` for VXLAN and Wireless). It is distinct from a native `Net::Connector::Base` device instance. Borrowed native sessions are accepted by `CtxDriver::Reader` and `Vxlan::Collector#collect_session`; they are never implicitly connected or retried.

For native sessions, the host holds `native.with_operation(:vxlan)` around the full collection so other tasks cannot interleave commands. Register the snapshot inside that block if it must survive a later lease/close failure; the host reports finalization errors separately. The collection CLI owns this lifecycle; its reports distinguish acquired evidence from confirmed file publication. See [the CLI guide](bin/README.md) for private output directories and cancellation behavior.

## Domain vocabulary

VLAN IDs, VNIs, VRFs, and NVE members are separate identities. Configuration review joins VLAN mappings and NVE members by VNI; it does not infer operational reachability. `BgpNeighbors` enumerates configured neighbors after peer-template inheritance, not established BGP sessions. `PrefixListReferences` describes route-map selectors and their routing consumers; those references do not by themselves prove route acceptance.

Association findings include `vni_layer_conflict` for explicit EVPN or VRF definitions that disagree with the NVE member's L2/L3 role, and `nve_l3_without_vrf` for an L3 NVE member without a configured VRF using its VNI. A VLAN mapping alone does not establish an L2 role: VLAN-backed L3 VNIs are supported. These findings are emitted only from complete configuration evidence and do not change the syntax status.

Routing facts retain their protocol and owner scope. Network statements require a matching IPv4/IPv6 process or VRF address family; neighbor policy maps belong to neighbor or peer-template address families. Unsupported routing families and misplaced settings remain partial evidence and produce no corresponding policy consumer.

Repeated prefix-list or route-map sequence identities are excluded within their policy name and kind, including subsequent declarations of that sequence. Independent sequences remain available as partial facts; their source capture paths use the final result indices. These partial policy entries do not establish the complete policy's behavior.

## Development and tests

Name shared classes by their responsibility and use the namespace for platform context. Preserve filenames and class names that directly match device commands.

`CiscoNxos::ConfigurationState` holds mutable facts during a single parse; `Vxlan::Configuration` is the public parsing entry point. The former `CiscoNxos::Configuration` constant and its `finish` method remain compatible aliases. Internal method names distinguish parsing (`parse_next_hops`), diagnostics (`unparsed_records`), and conflict exclusion (`exclude_ambiguous_records!`, which removes every record with a repeated identity).

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` runs RSpec, RuboCop, and the offline examples. Tests live in `spec/`, following the existing project's RSpec convention; fixtures use synthetic or sanitized evidence. Add regression cases for successful, incomplete, unsupported, and malformed inputs when extending a parser. Offline tests do not certify all device versions or replace live integration checks.

Use the declared minimum Ruby version for compatibility checks. Document source methods and non-obvious business logic in concise Chinese, preserve public return/error contracts, and never add raw device captures or credentials to examples, fixtures, logs, or release archives.

Run `bundle exec ruby -Ilib benchmark/tables.rb` to compare local parsing and reference-building costs for 500, 2,000, and 5,000 entries. Each case checks its result and reports the fastest of three samples plus allocated objects. These synthetic measurements do not measure device or network performance.

## Release

This directory can be maintained as the independent [vxlan](https://github.com/gatework/vxlan) repository. Update `VERSION` and `CHANGELOG.md`, run the validation and build commands above, and inspect the packaged file list before tagging `vVERSION`.

CI runs tests, lint, examples, build, and an isolated installation on Linux and macOS. After CI passes on `main`, push `vVERSION` to run the release workflow. It publishes the tested Linux artifact to RubyGems and GitHub Releases, attaches `SHA256SUMS`, and verifies downloaded bytes. The GitHub `release` environment accepts a `RUBYGEMS_API_KEY` secret; without it, configure RubyGems Trusted Publishing for this repository, `release.yml`, and the `release` environment. Retry a failed publish job to reuse its CI artifact; an already published version must have identical bytes. See [release details](docs/release.md).

Publish dependency gems first. A Git tag, a successful build, or a workflow file does not establish that the gem has reached RubyGems; confirm the registry result separately. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

MIT. See [LICENSE](LICENSE).

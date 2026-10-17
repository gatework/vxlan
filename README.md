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

## Public contract and limits

`Configuration.new.parse(text, complete: false)` returns a configuration observation. `RuntimeParser.new(platform: :cisco_nxos, model: nil).parse(name, text, complete: false)` returns a named runtime observation. `ParserRegistry.fetch(platform, model:)` exposes a declared profile for command-specific parsing.

Complete transport is necessary but insufficient for complete parsing: unknown syntax, conflicting identities, incomplete references, and ambiguous empty tables retain diagnostics. Configuration association findings are separate from syntax completeness and runtime health. IPv6 prefix-list facts do not imply IPv6 underlay inventory support.

`Collector#collect(connector:, target:, fabric_key:, model: nil, dimensions:)` uses a host-supplied connector; device identity, credentials, persistence, reconciliation, and concurrency policy belong to the host. This gem includes no fabric planner, provisioning engine, Rails models, or `Vxlan::Sync`. Loading or running the offline example does not access a device.

The collector copies target identity, fabric identity, and dimension selection before opening the connection. `Observation` names must be symbols; each `Snapshot` dimension must hold an `Observation` with a matching name. Both objects use their metadata-only `inspect` representation for string interpolation.

Conflicting singleton configuration values are excluded and reported as partial evidence, including interface, NVE, routing, VRF, and vPC settings. An interface with a conflicting VRF, or a BGP neighbor or template with conflicting settings, is excluded before deriving addresses or inherited facts; unresolved peer templates produce no neighbor projection. Unsupported routing nesting stays partial. Runtime output containing pagination or terminal editing controls returns `partial` with no records because its row boundaries cannot be trusted. Port-channel member conflicts are excluded across both wrapped lines and separate groups.

Detailed vendor behavior, historical validation notes, and Motor-only integration are preserved in [the architecture reference](docs/architecture-zh.md). Host integration examples in that reference require Motor; they are not standalone gem APIs. Motor adapters live under `backend/lib/baseline`, `backend/lib/vxlan`, and `backend/lib/wireless` in the [Motor repository](https://github.com/gatework/motor/tree/main/backend/lib).

The lifecycle connector is a host adapter exposing `open { |session| }` (and `platform` for VXLAN and Wireless). It is distinct from a native `Net::Connector::Base` device instance. Borrowed native sessions are accepted by `CtxDriver::Reader` and `CtxChecker::Collector#collect_session`; they are never implicitly connected or retried.

## Domain vocabulary

VLAN IDs, VNIs, VRFs, and NVE members are separate identities. Configuration review joins VLAN mappings and NVE members by VNI; it does not infer operational reachability. `BgpNeighbors` enumerates configured neighbors after peer-template inheritance, not established BGP sessions. `PrefixListReferences` describes route-map selectors and their routing consumers; those references do not by themselves prove route acceptance.

## Development and tests

Name shared classes by their responsibility and use the namespace for platform context. Preserve filenames and class names that directly match device commands.

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

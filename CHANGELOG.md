# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## Unreleased

## 0.7.0 (2026-10-29)

- Compose the shared snapshot contract and remove the synthetic collection observation. Whitelist public target identities and validate timestamps and dimensions.
- Normalize OSPF process_id, router_id, neighbor_address, symbolic state and neighbor_role while retaining priority and uptime.
- Delegate interactive apply to ctx_cli, resolving credentials through net-connector, including empty overrides and platform enable passwords.
- Use schema 3 reports and named checksummed plans. Older files must be regenerated.

## 0.6.0 (2026-10-29)

- Require RuntimeParser platform at construction and add parse_many. Rename Snapshot Ruby members to observations/observation while retaining dimensions in persisted reports. Use Catalog and shared Credentials in CLI; reject selected duplicate addresses across platforms before connecting.

## 0.5.1 (2026-10-24)

- Validate EVPN configured-peer totals within each VRF and address-family block, retain administrative shutdown and unknown AS identities, and preserve state-valued prefix totals.
- Use shared CLI argument and diagnostic boundaries for apply; preserve exit status, cancellation and uncertain journals when stderr fails, without replaying commands.
- Consume JSON Pointer configuration provenance and leave shared gem dependency versions to host lockfiles.

## 0.5.0 (2026-10-23)

- Consume immutable string-keyed Runner summary documents throughout reports and progress callbacks.
- Use English diagnostics, CLI help, change plans and Fabric review reports.
- Require Runner 0.2, net-connector 0.18 and the coordinated command receipt protocol.

## 0.4.2 (2026-10-23)

- Migrate shared CLI entrypoints to ctx_cli 0.2.0 names without legacy aliases.
- Delegate offline review entrypoint orchestration to ctx_cli and bound external evidence, plan, checksum and Fabric policy reads.
- Share offline evidence validation and JSON conversion with Runner; reject missing snapshot target identities.
- Use explicit field separators and align CLI dependency floors with shared inventory support.
- Delegate shared command dispatch, option groups, initialization, terminal confirmation, offline IO and collection entrypoint flow to ctx_cli; retain domain and Runner responsibilities.

## 0.4.1 (2026-10-22)

- Delegate command dispatch, common options, initialization, terminal interaction, offline IO and collection entrypoint orchestration to ctx_cli 0.1.0.
- Keep domain policies, device capabilities and ctx_runner completion semantics in their existing layers.

- Delegate batch completion and cancellation/failure precedence to CtxRunner::Batch, keeping domain review and CLI presentation explicit.

## 0.4.0 (2026-10-22)

- Delegate batch completion and cancellation/failure precedence to CtxRunner::Batch, keeping domain review and CLI presentation explicit.

- Centralize inventory selection and CLI filters in Net::Connector::Inventory; add vendor/model inclusion, exclusion and matching modes.


- Delegate shared collection, evidence and execution contracts to ctx_runner.
- Preserve domain parsing, change policies, CLI layouts and connection ownership.

## 0.3.1 (2026-10-21)

- Index Fabric address-group evidence by referenced object, preserving host order and missing dependencies without repeatedly searching every host's reference list.
- Add repository-specific AGENTS.md and a full Fabric review benchmark.

## 0.3.0 (2026-10-20)

- Require ctx_driver 0.2.4+ for the current net-connector session protocol; CLI configuration and progress use net-connector 0.16.0.

- 设备目录只保留 TXT 诊断，结构化采集事实统一移入 evidence/；离线审查只读取新目录。
- Review 布局 v3：对齐 topology 的 summary.txt/json、devices/*.txt、scripts/*.cfg、plan.json/SHA256 和 events.jsonl；不生成 Markdown。诊断先合并后发布，聚合计划必须 --item 选择单项并交互确认。

- Rename the public configuration parser to `Vxlan::Config` (`vxlan/config`), updating CLI callers, examples, tests and documentation without compatibility aliases. Evidence and review helpers now live under `Config::Evidence` and `Config::Review`.

- 与 net-connector 备份共用批次终端进度、阶段心跳、异常分类和结束摘要；JSON 独立输出，终端故障保留安全诊断且不重采。初始化并发继承公共 `NC_PARALLEL`，不再把公共值或默认 4 固化进 YAML。

- Model ACL meaning as an immutable `AclPolicy` and each supported change as a validated `ChangePlan` subtype. Use one frozen plan through confirmation, sending and readback; copy session snapshots so a reused reader buffer cannot overwrite the starting state. Reuse resolved ACL policies within one review without caching across calls.
- Share the complete-configuration gate across local advice, Fabric review and typed plans; reject ambiguous offline device identities, and report L2 VLAN differences, single-leaf VNI reuse, unequal-prefix subnet overlaps and unknown ACL dependencies.
- Recheck gateway addresses and overlapping subnets, VNI uniqueness and newly created ACL binding scope after apply; require an eligible before snapshot in `ChangePlan#satisfied?` and preserve uncertain outcomes when target fields appear alongside unplanned configuration drift.
- Reject repeated collection callbacks without replaying reads or overwriting acquired facts; validate BGP identities across repeated logical scopes and ASPLAIN/ASDOT forms.
- Validate BGP scope and contradictory routing identities, exclude ambiguous CDP fields and reject invalid NVE multicast values.
- Persist new report directory entries before execution, share device artifact naming, index address-group sequences and reuse one configuration fingerprint per device.
- Remove the legacy `CiscoNxos::Configuration` loading alias and `finish` alias; use `ConfigurationState#finalize_facts` directly with `Vxlan::Config` as the public parser.

- CLI 配置统一使用 net-connector 0.16.0 的分层加载器，遵循命令行 > 进程环境 > YAML > `.env` > 默认值；支持公共配置复用、来源追踪及用户目录初始化。

- Isolate each collection's effective environment and freeze its validated Fabric policy before opening sessions; switching environment files no longer reuses previous credentials or inventory defaults.
- Require aggregate plan checksums and explicit item selection for every apply; reject standalone legacy plans and missing/repeated session callbacks, and preserve uncertain finalization outcomes.
- Model Fabric roles and deployed services explicitly, including incomplete VLAN/NVE/EVPN associations; check inherited multicast, tenant routing, ACL dependencies and cross-VNI subnet conflicts before proposing a typed VLAN/VNI association.

- Audit explicitly scoped Fabric leaf groups for common deployed VNI gateway and ordered ACL consistency; preserve deployment differences, flag undefined attached ACLs and cross-VNI subnet conflicts, and block conflicting policy propagation.

- Make configuration script export opt-in with `--scripts`; add typed per-device plans and a TTY-only `apply` command with exact confirmation, fresh configuration guards, durable step checkpoints, no retry/automatic rollback, and configuration readback verification.

- Generate evidence-backed, review-only remediation recommendations during collection and through the offline `review --batch` command, including prerequisites, blocked parameters, conditional rollback, verification commands and source hashes. Configuration drafts are fully commented; no device changes are executed.

- Support live NX-OS variants: unavailable NVE router MACs, empty optional CDP UUIDs, starred down vPC members and wrapped consistency reasons, plus MAC/L2RIB flag legends.
- Derive BGP route-type columns from supported header declarations, with or without a repeated `PfxRcd` column; retain identity, duplicate-column and prefix-count validation.
- Exclude local Netdisco inventory caches from version control.

- Validate BGP route-type totals and isolate equivalent configured IPv6 host/prefix identities without changing retained key spelling.
- Publish incomplete summary checkpoints before finalization; retain safe checkpoints, recover committed failures/cancellation, invalidate stale success on repeated finish, and report unconfirmed recovery without replaying device queries.
- Add traceable evidence specimens, independent literal expectations, private saved-capture replay and isolated targeted mutation verification tools.

- Centralize static and discovered device validation before public configuration output, reject false filter lists, and isolate state when a CLI runner is reused.
- Index completed hosts once when building pending-target summaries and document safe report publication states.
- Normalize BGP summary peer addresses before identity checks and prefix-statistics association.
- Validate configured neighbor addresses without discarding valid siblings, and keep misplaced BGP address-family switches partial using one shared routing-scope guard.

- Align CLI help, plan/no-progress aliases, initialization guidance and operator documentation with net-connector examples; preserve invocation-directory defaults.

- Add the installable `vxlan collect` / `vxlan parse` command, sharing implementation with thin source examples.
- Move CLI implementation and templates out of examples; preserve source defaults and use user working directories for installed commands.
- Remove superseded examples/support files and duplicate example templates.

- Load existing environment defaults before initializing host configuration, honoring the selected config path without copying credentials.
- Preserve batch summaries and pending targets on scheduler failures; retain an incomplete execution status even after all device reports were saved, without exposing exception details.
- Mark every requested dimension failed when a connector returns without providing a session, instead of reporting empty evidence as complete.

- Collect native NX-OS observations under one operation lease without redundant session wrapping; preserve acquired facts on finalization failure.
- Reject prematurely exited/killed collection workers and join all owned threads before propagating failure.
- Register acquired results before publication, distinguish saved reports from acquired evidence, and preserve cancellation when summary publication also fails.
- Reject non-private or symlink report roots; sync published directory entries and report safe publication phases without exposing raw filesystem errors.

- Add borrowed-session collection with configuration-first dependent observations; retain requested dimension order.
- Add host examples for configurable batch collection, safe per-device reports and offline file parsing. Keep net-connector and dotenv outside core runtime dependencies.

## 0.2.3 (2026-10-18)

- Validate optional IPv4 next hops following static-route output interfaces without changing route fields or option text.

- Clear Bundler bootstrap variables when verifying packages in an isolated gem installation, including calls made through bundle exec.

- Reject unsupported or misplaced VRF address families before projecting targets and policy consumers, and validate anycast gateway MAC values and static-route next-hop forms.

- Parse runtime line boundaries and wrapped records independently of the host Ruby input/output record separators.

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

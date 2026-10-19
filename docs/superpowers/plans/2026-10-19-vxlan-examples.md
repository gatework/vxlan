# VXLAN examples implementation plan

> Execution: native in the current checkout, as requested by the user's “直接做”. No new commit or device operation is requested.

**Goal:** Provide practical VXLAN collection and offline parsing scripts with the configuration, help and report experience of net-connector/examples.

**Architecture:** Keep Vxlan a pure observation library. Host scripts own inventory, optional net-connector, credentials, parallelism and persistence. Reuse Collector's parsing and evidence semantics and add a borrowed-session entry point so host code can explicitly own native sessions.

**Tech stack:** Ruby >=4.0.6, RSpec, stdlib OptionParser/YAML/JSON, existing ctx_parser/ctx_driver; optional net-connector and dotenv for collection examples.

## Requirements and decisions

- Core runtime dependencies must not gain net-connector or dotenv.
- Offline parse accepts configuration or a supported runtime dimension, a file/stdin, and explicit complete-transport declaration. Human summary by default, JSON on request.
- Live collect reads static devices from YAML or optional Netdisco settings, selects devices, validates all inputs before connecting, and runs devices concurrently while each device's commands remain sequential.
- `.env` supplies credentials without overwriting existing environment; CLI > YAML > environment defaults. Paths resolve against project root, explicit config paths against the invocation directory.
- `--help`, `--examples`, `--init`, `--inventory-only` must never connect to devices. Missing files offer creation only on a terminal; automation requires explicit `--init`.
- No passwords in YAML, generated templates or public console output. Host-key default strict. Parallel default 4, limit 500. Missing credentials fail before connections. No scan, no arbitrary query, no write commands.
- Reports use hostname-IP device identity, restrictive permissions, atomic per-file publication, JSON facts plus readable per-device and batch summaries. Complete evidence is not a fabric health verdict.
- Default Rake/package verification must execute only offline demonstrations/help, never live examples by glob.

## Tasks

- [x] 1. Collector: regression tests for borrowed sessions (no open/close), shared collection failures, configuration-first dependent queries; implement `collect_session` and reuse the path from lifecycle collection; run collector specs.
- [x] 2. Host examples: failing tests for CLI help without optional dependencies, config precedence, initialization/no overwrite, invalid selectors/dimensions, missing credentials, sequential fake receipts, batch isolation, reports and exit statuses. Implement `examples/parse.rb`, `examples/collect.rb`, and focused support classes under `examples/support/`.
- [x] 3. Docs/packaging: explicit offline example task, YAML/env templates and examples README, English/Chinese top-level usage, package allowlist and installed help checks. Verify RSpec/lint/examples, gem build, isolated installation and source runtime boundaries.

## Review focus

- Empty/malformed inventory and duplicate hosts must fail or report no targets, never silently succeed.
- Incomplete or unsupported evidence must retain status and issue codes; configured association issues are not runtime health.
- Failures during connect/command/close must preserve acquired evidence and release owned sessions.
- Config/env path resolution must work from examples/ and project root without reading sibling checkouts.
- Packaging must exclude real local credentials, device captures and generated output; helpers must not execute on load.

## Execution evidence

- Dependencies ctx_parser/ctx_driver 0.2.4 fetched from RubyGems, not neighboring checkouts.
- Red/green checks: missing borrowed-session API; missing example files; interrupted pending-count reporting; initializer parameter validation.
- RSpec covers local PTY native connector ownership, real bounded pool, static/Netdisco inventory, config/env priority, initialization, failure isolation and report persistence.
- Final commands: `bundle exec rake`, `bundle exec rake build`, `ruby script/verify_package.rb pkg/vxlan-0.2.3.gem`. Logs under /tmp/vxlan-*.log.
- Core and package runtime dependency checks exclude net-connector/dotenv. Source paths and locally installed library checked after installation.
- No device networking, configuration writes, Git commit, push or publish performed. Live NX-OS behavior remains unverified.

Ruling: published net-connector 0.14.1 still uses concurrency/ and lacks the local resources helper. Host parallel dispatch therefore lives in examples/support/parallel.rb, independent of connector internals. Verify the real published gem separately from the locally refactored installation.

Published SDK check: downloaded original net-connector 0.14.1 gem into a separate temporary GEM_HOME; verified loaded path and ran native PTY plus collection/Netdisco specs successfully. Thread-pool regressions cover a blocked sibling on failure and partial thread creation before the startup gate.

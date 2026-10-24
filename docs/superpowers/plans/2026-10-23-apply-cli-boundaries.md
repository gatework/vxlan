# Apply CLI boundaries implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Reuse existing parameter/output capabilities and preserve apply failure/cancellation outcomes when stderr fails.

**Architecture:** CtxCli::Command parses, Terminal confirms, Output delivers safe diagnostics. VXLAN/Wireless select and validate plans, acquire credentials and own session leases. CtxRunner::Execution owns effects and journals. No new abstraction or state machine is introduced.

**Tech Stack:** Ruby 4.0.6, RSpec, existing project Bundler/rake and gem verification scripts.

**Spec:** docs/superpowers/specs/2026-10-23-apply-cli-boundaries.md

## Global Constraints

- Preserve WIP and concurrent dependency edits; use two isolated worktrees with guarded copy-back. No commit, push, release, constraint restoration or evidence deletion.
- Chinese method comments and English eight-module implementation literals; preserve Wireless domain language and vendor layouts.
- Keep port 22, execution-directory defaults, all flags and full confirmation tokens. Do not add --yes or implicit plan selection.
- Ten scoped files: each consumer's apply implementation, apply spec, CHANGELOG and README; this plan/spec live in VXLAN. Current selected dependency bytes and metadata must be identified in package evidence.

## Review Focus

- Broken stderr before credentials/connection returns 2 and does not consume confirmation or send commands.
- Broken stderr after one uncertain command or interruption preserves status 2/130 and its journal without replay.
- Failed journal finalization cannot mask the original result or disable later failure diagnostics.
- Help with positional arguments is rejected; ordinary help avoids TTY, file reads, credentials and connections.
- A reused apply instance starts a fresh parse/execution state, and the refactor leaves exact domain selection, checksum, token and lease behavior intact.

### Task 1: migrate both apply consumers to existing CLI boundaries

**Files:** vxlan/lib/vxlan/cli/apply.rb, wireless/lib/wireless/cli/apply.rb; both spec/cli/apply_spec.rb, CHANGELOG.md and README.md; VXLAN plan/spec.

**Interfaces:** Consume existing CtxCli::Command.new/parse/informational? and Output.new/diagnostic. Produce unchanged Apply#run(argv) statuses 0/1/2/130 and unchanged Execution/session contracts. No shared-library implementation change.

- [x] Extend existing exercise helpers only for broken diagnostic streams and interrupted command writes. Add consumer regressions for preflight failure (including failed intent persistence), one-command error, and interruption; assert statuses, no extra writes and actual journal state/error. Add --help plus unexpected positional argument rejection, checking no input consumption or connection.
- [x] Run each `bundle exec rspec spec/cli/apply_spec.rb`. Expected: new diagnostic scenarios fail by escaping IOError; help/extra returns 0 instead of 2. Existing domain cases pass.
- [x] Replace direct OptionParser lifecycle with CtxCli::Command and use informational? before TTY/plan reads. Keep host-defined argument registrations and domain workflow. Route final errors and journal warnings through a per-entrypoint CtxCli::Output; preserve the existing Interrupt guard for the optional journal warning.
- [x] Run focused apply specs and both full `bundle exec rake` gates, plus existing ctx_cli default gate. Expected: all pass; domain checksum/selection/no-replay/readback tests retain their behavior. Add concise changelog/README notes.
- [x] Run one fresh independent review of the exact phase diff, spec and ledger. Re-grade findings, handle Critical/Important once with RED/GREEN and full affected gates; no second review.
- [x] Copy only hash-guarded scoped files to actual checkouts. Run both actual default rake gates and ordinary bin apply --help; build both exact candidate packages and run official package verifiers with explicit net-connector/Expect/Runner/CLI artifacts. Add an installed broken-stderr/interruption probe. Expected: actual and installed behavior passes, source bytes match and unrelated WIP remains.

## Self-review

All behavior requirements map to Task 1; existing fixtures already cover domain fingerprints, selection, persistence, callback count and readback. The shared Command tests cover fresh defaults and argv ownership; consumer help tests cover the integration boundary. The minimal direct error-rescue patch would leave duplicated diagnostic handling and parser behavior; existing components supply both without any new API. Current continuous implementation authorization settles native execution and reversible integration; no further approval is needed.

Verification follow-through: the Wireless package verifier needed one fixture field (`snapshot.target.host`) to satisfy the existing evidence identity contract. This scoped eleventh file was repaired after the independent ten-file review and verified by the official package gate and lint. See the phase ledger for the original failure and rerun results.

# VXLAN Connector Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task by task. Track completed checks here; do not commit existing WIP.

**Goal:** Harden the existing VXLAN host integration without new wrappers or business layers in net-connector.

**Architecture:** NativeConnector owns the original NX-OS connection and operation lease. Collector/ctx_driver retain parsing and evidence responsibilities. Existing host parallel and report helpers handle cancellation and persistence explicitly.

**Tech Stack:** Ruby >=4.0.6, RSpec, local PTY, stdlib filesystem/threads; optional net-connector ~>0.14.1.

**Spec:** ../specs/2026-10-19-connector-integration-design.md

## Global Constraints

- net-connector keeps Ruby >=3.2 and no vxlan/ctx_driver runtime dependency; vxlan keeps Ruby >=4.0.6.
- No new public wrapper, CLI, dependency, result model, parser, or automatic command replay.
- Preserve existing API/CLI/path semantics, WIP, and published connector compatibility.
- Work in an isolated copy of the complete current WIP, then transfer only owned changes after checking source fingerprints. No commits/push/publish or real devices.
- User's “继续” authorizes execution of the reviewed design; implement inline with one independent final review.

## Review Focus

- Lease finalization failure must retain completed observations (Task 1).
- Thread.exit/kill without an exception must not produce successful nil slots (Task 2).
- Cleanup failures must not replace the first cancellation/error (Task 2).
- JSON committed but TXT/fsync failed must remain distinguishable from unsaved output (Task 3).
- Cancellation plus failed summary must preserve exit130 and safe diagnostics (Task 3).

### Task 1: Original-session operation lease

**Files:** examples/support/collection.rb; spec/example_native_connector_spec.rb; spec/collector_spec.rb.
**Interfaces:** consume Net::Connector.open/with_operation and Collector#collect; produce unchanged Snapshot.

- [x] Extend native PTY tests to assert the yielded session is native and the entire callback owns an operation lease; reproduce missing lease.
- [x] Run `bundle exec rspec spec/example_native_connector_spec.rb spec/collector_spec.rb`; expect targeted new assertion FAIL.
- [x] Yield native within with_operation(:vxlan), removing redundant Session wrapper. Add evidence tests for connection failure, disconnect suppression, close/lease finalization failure and borrowed-session ownership; modify Collector only if reproduced.
- [x] Run the same command; expect all PASS.

### Task 2: Worker completion and cancellation

**Files:** examples/support/parallel.rb; spec/example_parallel_spec.rb.
**Interfaces:** map(items, parallel:) continues returning ordered block values or propagating the first failure after joining owned workers.

- [x] Add Queue-synchronized tests for worker Thread.exit/kill, interrupt with blocked sibling, and cleanup exception preserving original error; assert every worker stopped.
- [x] Run `bundle exec rspec spec/example_parallel_spec.rb`; expect early-exit/cleanup failures.
- [x] Track exhausted workers; register notifications outside interruptible setup; retain primary failure during cleanup. Keep bounded pool and resource preflight local and small.
- [x] Run the same command; expect all PASS, including partial-creation gate regression.

### Task 3: Report receipts, completed evidence and cancellation

**Files:** examples/support/collection.rb; examples/support/report.rb; spec/example_collection_spec.rb; new spec/example_report_spec.rb.
**Interfaces:** Report#write/#finish retain existing signatures; host-internal Report::Error safely identifies relative path, publication phase and committed state; no raw exception message.

- [x] Test Thread-safe result registration before write, JSON-success/TXT-failure, Interrupt with failed finish, ENOSPC, directory-fsync after rename, root symlinks/wide permissions and sensitive error text. Expect no device replay and pending excludes acquired targets.
- [x] Run `bundle exec rspec spec/example_collection_spec.rb spec/example_report_spec.rb`; expect missing error receipts/unsafe-root acceptance/cancellation propagation failures.
- [x] Implement scoped publication diagnostics, private-root preflight and directory sync; record collected result before persistence, report saved state separately, and handle report failure while building terminal summary. Keep cancellation precedence130 and ordinary persistence error2; only safe diagnostic text.
- [x] Run the same command; expect all PASS. Run full `bundle exec rake`; expect specs/lint/offline examples PASS.

### Task 4: Documentation, installed-package and independent review

**Files:** examples/README.md; README.md; README-zh.md; CHANGELOG.md; script/verify_package.rb only if required.
**Interfaces:** existing source scripts and gem allowlist remain unchanged.

- [x] Document operation ownership, safe borrowed-result retention, private roots, persisted-versus-acquired status, cancellation and unchanged module boundaries.
- [x] Run `bundle exec rake`, `bundle exec rake build`, and `ruby script/verify_package.rb pkg/vxlan-0.2.3.gem`; expect PASS and loaded source/package paths recorded.
- [x] Test native integration with original published net-connector0.14.1 separately from current connector checkout; record exact loaded paths/version. If connector source changes, run its affected tests plus Ruby3.2/full CI.
- [x] Independent final review against this plan/spec; reproduce and fix important findings with tests. Compare original file fingerprints and transfer only these task-owned files. No local commit.

## Execution ledger

Ruling: isolated full-WIP copy rather than clean HEAD worktree — examples under review are untracked WIP and must participate in implementation and baseline. No source credentials or captures are copied. Inline execution follows user's continuation instruction without another approval round.

Pre-flight: Tasks 1 and 3 share collection.rb; Task 3 preserves Task 1's open lease. Task 2 propagates unhandled report errors to Task 3; Task 3 must finalize only after the pool joins all workers.

Task 1: complete — task1-red reproduced missing operation lease/native boundary; native+collector14 cases passed, expanded finalization cases also pass. Collector product code unchanged.
Task 2: complete — task2-red reproduced silent Thread.exit success and killed-worker hang; task2-green5 cases passed.
Task 3: complete — task3-red reproduced seven report/cancellation failures; full-green242 cases, lint68 files and offline examples passed. Pending-target success additionally reproduced and fixed.
Ruling: report failure can now publish a truthful incomplete summary — update the old test that forbade any summary path; preserve acquired-versus-saved facts instead.
Ruling: existing worker helper remains local for published connector compatibility; do not import newer net-connector internals.
Task 4: in progress — build passed; package verification, independent review and connector source/published matrix pending.

Task 4: complete — full rake242 examples/0 failures,68 lint files clean, offline examples pass; build and isolated package verification exit0. Published0.14.1 and current connector checkout each44 integration examples/0 failures with loaded paths recorded. Independent reviewer44 examples/0 failures and no important findings. No connector product changes, real device IO, commits or publishing.
Final transfer: original full-WIP fingerprints checked before transfer; copy only the12 changed implementation/test/doc files and this plan/design. Re-run canonical rake in original checkout to verify transferred result. Logs/candidate remain in the isolated temporary directory for review.

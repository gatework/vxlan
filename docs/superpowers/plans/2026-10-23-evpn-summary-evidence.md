# EVPN summary evidence implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline, with one fresh final reviewer.

**Goal:** Interpret documented EVPN neighbor and statistics evidence without silently accepting missing declared neighbors or dropping known down states.

**Architecture:** Keep command grammar and peer/statistics association in the current platform parser. Separate neighbor normalization, statistics-row association and declaration validation into small private operations where each expresses a distinct invariant. Reuse existing scope splitting, duplicate identity protection and count mismatch diagnostics.

**Tech Stack:** Ruby 4.0.6, RSpec, project Bundler/rake, existing contract and package verification tools.

**Spec:** docs/superpowers/specs/2026-10-23-evpn-summary-evidence.md

## Global Constraints

- Nine VXLAN scoped files plus one Wireless test dependency repair: current parser, existing parser spec, README, CHANGELOG, docs/evidence-contracts.md, script/verify_contracts.rb, spec/cli/apply_spec.rb and this plan/spec; Wireless only adds its direct apply require in the existing apply spec. No new shared API, dependencies, version or vendor layout changes.
- Worktree starts with 149 byte-matched actual files, including WIP. No commit/push/release, constraint restoration or removal of evidence/worktrees.
- Preserve output completeness versus neighbor health, unknown AS and unknown prefix total explicitly. Do not infer service expectations or issue device changes.
- Source references document exact observed formats; supported field relationships are stated in the spec, without all-version/device claims.

## Review Focus

- Counts stay within physical scope, while conflicting router and duplicate peer identities still invalidate the logical scope.
- Capable is never treated as the total row count; repeated contradictory counters cannot be erased by a later original value.
- AS 0 cannot become a valid established AS; nil can join only a matching unknown-AS statistics row.
- State-valued PfxRcd, multiword administrative states, optional totals and absent/duplicate/invalid type columns cannot silently change state or associate statistics to the wrong peer.
- Malformed decorations, invalid integers, zero-prefix established rows and explicit empty tables preserve their distinct evidence meanings.

### Task 1: enforce documented summary evidence

**Files:** lib/vxlan/cisco_nxos/parsers/show_bgp_l2vpn_evpn_summary.rb; spec/cisco_nxos/show_bgp_l2vpn_evpn_summary_spec.rb; README.md; CHANGELOG.md; docs/evidence-contracts.md; script/verify_contracts.rb; spec/cli/apply_spec.rb; this plan/spec. Wireless spec/cli/apply_spec.rb only corrects its own direct require.

**Interfaces:** Consume unchanged `.parse(text, complete:)`; produce unchanged Result shape with documented state strings, optional `remote_as: nil` only for newly accepted unestablished AS 0 rows, and stable existing numeric AS semantics. Keep prefixes_received nil for down states.

- [x] Add focused behavior cases for configured counts, zero/absent declarations, contradictory counts and separate scopes; administrative state and AS boundaries; known decorations; state-valued statistics and mismatched/duplicate/missing statistics. Reuse existing test helpers and fixtures.
- [x] Run `bundle exec rspec spec/cisco_nxos/show_bgp_l2vpn_evpn_summary_spec.rb spec/runtime_parser_spec.rb`; verify new cases fail for the intended evidence defects while the original 40 cases still pass.
- [x] Implement the private parsing boundaries described above; do not loosen unknown grammar or introduce fallback APIs. Run focused specs to GREEN.
- [x] Add source-backed contract/README/changelog notes. Update contract mutation locations to the current parser guard and isolated selected Runner implementation, preserving all existing mutation cases and their non-assertion control. Run `bundle exec rake` and `bundle exec ruby script/verify_contracts.rb`; record selected dependencies and source paths.
- [x] Run one fresh independent review of the exact phase diff, spec, ledger and official source evidence. Re-grade findings by behavior; perform one Critical/Important fix pass with RED/GREEN and full affected gates, no re-review.
- [x] Guard and copy scoped files to the actual checkout; run actual default rake, contract checks and ordinary parse entrypoint. Build and verify the exact candidate, including installed grammar probes and unchanged earlier apply behavior. Compare final source/metadata/package bytes and original WIP hashes.

## Self-review

The fix follows evidence fields rather than collapsing parsing into a generic parser. Configured-peer totals describe the unfiltered command returned by the profile; a caller declaring filtered output complete can only receive partial evidence when counts disagree. Capable/established equality is deliberately not inferred. Existing terminal/identity/prefix upper-bound contracts remain in force. Continuous implementation authorization covers this local correction and guarded copy-back; no new approval gate is needed.

Review status: completed on 2026-10-24 by a fresh independent reviewer after two earlier starts failed with workspace credit exhaustion. No Critical/Important/Minor findings; 89 independent direct-source checks plus complete:false passed. Actual source, full gates and exact installed candidates were already verified; final acceptance packaging includes this updated plan. See .ctx-evpn-audit-20261023/review-findings.md and .ctx-evpn-acceptance-20261024 for evidence boundaries.

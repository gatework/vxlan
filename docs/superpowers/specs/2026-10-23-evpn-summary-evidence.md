# EVPN summary evidence boundaries

## Problem and scope

The current NX-OS EVPN summary parser ignores declared neighbor counts, drops documented administrative shutdown and AS 0/Idle rows, and rejects a documented Idle row in the optional route-type statistics table. These are evidence interpretation defects: collection completeness and neighbor health must remain separate.

Only the existing `ShowBgpL2vpnEvpnSummary` implementation and its direct verification/docs change. Keep the vendor command filename/class, Result/Observation interfaces, profile commands and caller-owned completeness contract. No generic BGP framework, legacy API, connection changes or inferred configuration are needed.

## Source evidence

- [NX-OS 9.3(x) configuration guide](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus9000/sw/93x/label-switching/b-cisco-nexus-9000-series-nx-os-label-switching-configuration-guide-93x/b-cisco-nexus-9000-series-nx-os-label-switching-configuration-guide-93x_chapter_01000.html) contains four configured neighbors, one capable neighbor, three administrative shutdown rows and inbound soft-reconfiguration statistics.
- [Cisco DevNet NX-API CLI reference](https://developer.cisco.com/docs/nx-api-cli-reference-for-the-cisco-nexus-9000-series-platform/bgp-commands/) shows an EVPN Idle neighbor with AS 0 and a dampening summary. AS 0 is retained as unknown (`remote_as: nil`) for a non-established row; it is never accepted as an established AS.
- [Cisco multisite troubleshooting](https://www.cisco.com/c/en/us/support/docs/switches/nexus-9000-series-switches/215780-troubleshoot-evpn-vxlan-in-multisite-env.html), updated 2022-10-17, includes three main-table neighbors and three route-type rows, with Idle in both tables. Its component list identifies that border gateway as N9K-C93108TC-FX, NX-OS 9.3(1).

These are published-format evidence, not local real-device verification. Tests use independently assembled documentation-style input with reserved addresses and controlled counters; do not copy a document's complete transcript or represent synthetic fixtures as live captures.

## Required behavior

1. Count every parsed main-table neighbor against every configured-peer declaration in its physical VRF/AF block. Keep complete blocks separate. A missing/excess row or contradictory declaration yields partial evidence while retaining unambiguous rows. A valid zero declaration proves an empty EVPN table. Count-free historical format remains supported.
2. `capable` is a different count: do not compare it to all neighbor rows or infer a peer's health from it. Reject impossible capable > configured and contradictory repeated count pairs. Do not assume capable equals the number of currently established rows in all versions.
3. Keep `Shut (Admin)` as normalized `shut_(admin)`, with no received-prefix total. Preserve existing normalization of other states. Non-established AS 0 becomes nil; nonzero valid AS remains numeric. Reject AS 0 for established rows and AS values outside the 32-bit range.
4. Recognize only the documented, fully shaped soft-reconfiguration/dampening summary lines. Unknown or malformed decorations still make the output partial.
5. The optional route-type table joins by normalized VRF/AF/address and matching AS. If it has a PfxRcd column, numeric totals must match established rows; a state must match the non-established row's state, including multiword administrative states. Type counters remain nonnegative integers. With a known total, their sum cannot exceed it. With an unknown total, retain the shown counters without inventing a zero total or applying an unsupported upper bound.
6. Missing/repeated/mismatched/invalid route-type rows remain partial. Every main-table row must be accounted for if that statistics table is present. Prefix observations must not turn a down neighbor into an established neighbor. No statistics table remains a valid format.
7. Repeated physical blocks still pass the existing logical-scope identity conflict and duplicate-neighbor checks. `complete: false` always remains partial. Invalid scope, malformed rows and terminal corruption retain existing rejection.

## Delivery

RED/GREEN in the current WIP snapshot worktree, full default rake and evidence-contract verifier, one independent final review, guarded copy-back, actual checkout gates/ordinary parse entrypoint, package byte comparison and isolated installed parsing. Preserve all unrelated WIP and concurrent dependency metadata, with exact selected versions recorded. No commit, push or release.

Chinese implementation comments and English literals continue to apply. Tests and documentation are not subject to bulk language translation.

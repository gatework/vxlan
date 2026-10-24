# Apply CLI parameter and diagnostic boundaries

Continue the authorized eight-module review; Wireless participates as the existing shared-CLI consumer. The accepted shared CLI design says apply reuses parameter/terminal/output components while domain plan selection, validation, commands and operation leases remain local. Do not introduce a common apply workflow, move Execution accounting, or add adapters that duplicate the two domains' decisions.

Both current apply entrypoints directly build OptionParser and write final errors to stderr. A broken error stream can replace intended status 2 or 130 after the journal already recorded failure/interruption. Help also accepts unexpected positional arguments, unlike the existing CtxCli::Command boundary.

Use existing CtxCli::Command for fresh defaults, parsing and informational output, and CtxCli::Output for safe terminal diagnostics. Preserve every existing flag/default, exact confirmation token, per-domain preview text, checksum/selection rule, credentials policy, execution journal and session lease. Reject positional arguments including after --help before confirmation, file reads or connection. Informational help remains side-effect free. Runtime error messages remain safe and do not expose original exception text.

Broken stderr must not replace ordinary failure status 2 or interruption status 130, cause device replay, or erase execution facts. Report finalization warnings use the same diagnostic output component. Preserve the current special handling of interruption during the optional journal warning; do not introduce a new fatal-exception policy into shared Output.

Chinese method comments and English business literals apply to the eight requested modules. Wireless's existing domain language is preserved; this phase does not perform a bulk translation. No new public API, flags, dependencies, compatibility paths, version-constraint edits, commits or publication. Keep concurrent WIP using before/after hashes.

Acceptance uses existing domain apply fixtures and real journal files, then complete module gates, actual ordinary CLI entrypoints and isolated packages with explicit dependency artifacts. Selected installed versions are evidence only for that combination, not the concurrently widened dependency ranges. Real network/device behavior is unclaimed.

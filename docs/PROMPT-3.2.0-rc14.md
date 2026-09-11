# RC14 focused repair brief

Use the checksum-verified RC13 archive and the operator's pasted two-pass summary.
Investigate `wa-rc3-late-send-after-account-change-retains-draft`; do not infer a
missing dependency from an executed ERT failure. Distinguish the new failure from
the earlier RC11 stale-transport fixture.

Restore the production stale-send error state without changing the existing failing
test, moving identity checks, weakening acknowledgement validation, clearing drafts,
exposing old account/recipient/message data or adding a retry. Keep unrelated work
out of this repair. Add native regression cases for token and URL changes, accepted
and malformed/failed replies, original and edited drafts, reply/undo preservation,
duplicate callbacks, current-buffer isolation and ordinary successful acceptance.

Run the full controller twice on frozen code. Preserve actual failures, partial
coverage and runtime blocks; a structural check is not ERT. Verify cumulative
manifests, original-test preservation, exact update/rollback, unknown-edit refusal,
patch roundtrip and final archive hashes. Never present operator RC13 successes as
RC14 execution. No live message, service or remote repository mutation.

Deliver a uniquely named RC14 complete cumulative bundle and review patch. Provide
a single fish function that restarts the operator's already identified service
ONLY after successful full audits, installation and installed-payload verification.
Keep the init, Guix profile, sessions and independently newer PQ files untouched.
State the remaining native/live acceptance without inventing success.

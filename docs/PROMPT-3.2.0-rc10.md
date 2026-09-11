# RC10 repair brief — executed scope

Use the two uploaded RC9 diagnostics, not guessed repository state. Verify archive
identity and both source fingerprint maps against the complete retained RC9 source.
Find every failure in the combined and dedicated suites and distinguish duplicated
reporting of one assertion from independent failures.

Fix profile-event validation order: malformed events must fail before cache/stale
filtering. Keep valid unrequested events ignored without recording presence history.
Keep group photos while rejecting group-wide availability/activity. Do not change
the existing expected HTTP 400 assertion, add skips, fake a green native report,
relax authentication, remove cache bounds, or silently change provider subscriptions.

Add focused cached/uncached, valid/invalid, flat/native, stale-event, group-photo,
message-state and no-upstream-request regressions. Improve compact Python failure
identification through bounded private receipts, never raw traceback/subtest values.
Test malformed receipts, links, size caps and the read-only summary behavior.

Do not add unrelated UI, player, crypto or provider features. Preserve RC8/RC9
responsiveness and media behavior. Run both full audits against frozen code, record
native tools that cannot execute, and keep uploaded RC9 passes distinct from RC10.

Deliver a new RC10 complete cumulative archive with explicit prior content anchors,
reviewable RC9 delta, EN/PT-BR docs, SHA-256 checks and provenance. Verify package
roundtrips, rollback, unknown edits, state preservation and the real refusal gate.
Provide one fish command using the existing Guix toolchain. Do not require a prior
successful RC9 installation or disable the two-audit gate. No user-machine access,
push, VPS change, real WhatsApp message or service restart is authorized here.

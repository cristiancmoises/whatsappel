# RC17 engineering brief — malformed send-response failure

Work from the SHA-256 verified delivered RC16 archive, not the incomplete RC16
review or a guessed current remote HEAD. The operator reports the same ERT test
in two full runs: whatsapp-workspace-send-failure-retains-draft-and-reply. Their
activation receipt says installed=false and restart_attempted=false. Historical
RC11 reports have different failures and are not evidence of the current run.

Inspect the original regression and every production operation reachable from its
callback. Diagnose the contract violation before modifying behavior. Preserve the
original test file and assertions byte-for-byte. Make the smallest correction;
never bypass the native gate, accept malformed acknowledgements, clear drafts or
reply context on failure, leak provider text, retry sends, or change recipients.

Specifically check non-list failure payloads: JSON decoder sentinels are not
association lists. A warning formatter must tolerate those payloads. Retain the
existing safe-message allowlist and use a constant fallback. Add native tests for
immediate/deferred completion, newer draft text, reply identity, point/marker/undo
preservation, invalid/scalar payloads, allowlisted and untrusted error fields,
duplicate callbacks, buffer closure, account changes and normal acceptance.

Use native Emacs when actually available. A Python structural scan is not ERT.
Record failed runtime-acquisition attempts; do not fabricate native results.
Execute baseline and two final full audits against frozen source. Keep partial,
blocked and failed results distinct. Verify final payloads, cumulative update and
rollback, independently modified PQ/state preservation, and the real installer
refusal path without a mocked audit gate.

Deliver a uniquely versioned cumulative package, focused review diff, English and
Portuguese instructions, prompt, and raw audit evidence. Preserve two exact-candidate
full audits and fail-closed local activation. A failed update must not restart a
service. Do not push, deploy, repair webhooks, change profiles/init, or send real
messages. This is a send-failure handling repair, not proof of phone delivery,
photograph loading, Pale support or a measured performance improvement.

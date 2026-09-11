# WhatsAppel 3.2.0-rc8 — contact-selection implementation and validation

Prepared 2026-09-10. **Candidate; native and live acceptance is incomplete.**
The report concerns the retained RC7 source, not a remotely observed running Emacs.
The user's exact loaded version and freeze backtrace were not provided in this turn.
No claim is made that the single live root cause was reproduced or that all freezes
are fixed. Earlier operator RC5 successes are not RC8 test results.

## Evidence-based scope

Inspection of RC7 identified synchronous work directly reachable from opening cached
conversations: full cached-message insertion, native preview creation, and uncached
PQ decryption via `call-process`. The read worker already performed normal snapshot
HTTP asynchronously; this release does not mislabel those reads as newly asynchronous.
The old selection path could also update/rebuild root rows before returning.

RC8 displays an empty composer first, then uses a 50 ms normal timer for selected-chat
refresh/history work. Generation, buffer-lifetime and account guards discard obsolete
opening callbacks. Root selection changes properties without deleting row characters.
The timer is not a promise that all history arrives in 50 ms or that network I/O is fast.

Message previews default to 2,048 characters and clamp settings to 128..8,192. Original
records remain unchanged; explicit local pages contain at most 8,192 characters each.
Sender, reply and caption previews are separately bounded. This bounds selected display
work, not arbitrary bridge data, JSON parsing, string comparison or global process RSS.

The transcript renderer reuses ready image specs but never initiates native decoding.
Normal wall-clock timers replace scroll idle timers, scroll range queries do not request
forced redisplay, and ready image decoding is limited to one visible image per tick.
Individual native decoders can still block; this is not a decoder sandbox.

Uncached encrypted text is deliberately **explicit Decrypt**, not automatically opened
while selecting a contact. One owned asynchronous pqenv child per chat uses unchanged
identity/sender/age verification arguments, a ten-second deadline, a 1 MiB ciphertext
and output ceiling, and 64 KiB stderr ceiling. Ciphertext temp files are private and
removed with owned-process cleanup; plaintext is memory-only and cached by account/chat/
message/blob. Org capture reads that same scoped key. Original cryptographic code is
not changed. The subprocess fixture described below is NOT cryptographic validation.
Replay state may already have changed when an invocation is cancelled; no automatic
retry is performed. Legacy explicit synchronous APIs and encrypted sends remain.

`M-x whatsapp-selection-diagnostics` reports the loaded version, source directory,
Emacs version, selection-command duration and cache/pending counts without contact IDs,
message text, URLs or tokens. A manually enabled debug-on-quit backtrace can contain
private data and must be reviewed before sharing.

## Two completed full audits

Both runs returned exit **1**, with **5 PASS, 1 PARTIAL, 17 BLOCKED**. Python outcome in
each: **337 discovered/run, 313 passed, 24 skipped, zero failures/errors**. All skips
require the unavailable Guile runtime; this is PARTIAL, not a bridge pass.

| Gate | Result in both runs |
|---|---|
| Python suite | PARTIAL: 313 passed, 24 Guile-dependent skips |
| Structural Lisp shapes | PASS; not an Emacs/Guile compiler or evaluator |
| Existing read JSON and envelope benchmarks | PASS; no RC8 native timing claim |
| FFmpeg capabilities | PASS; retained tests also exercise synthetic media encoding |
| Source integrity | PASS; all 70 code/build fingerprints unchanged |
| Emacs compilation, ERT, native layout benchmark | BLOCKED: missing Emacs |
| Seven fish syntax gates | BLOCKED: missing fish |
| Guile unit and two bridge HTTP suites | BLOCKED: missing Guile |
| mpv local decoding | BLOCKED: missing mpv |
| Rust tests, format and Clippy | BLOCKED: missing Cargo |

Pass 1: `e767bc829f884b0a8253113c1cc1dcfd`, completed `2026-09-10T13:41:55.265510+00:00`.
Pass 2: `417ee1019ccc4e7c8cdb80cc0390d136`, completed `2026-09-10T13:43:15.610926+00:00`.
Both before/after fingerprint maps match. No code was edited between these runs.
Only prose and package/evidence assembly follow the final code audits.

## Added tests and honest boundaries

Eight new Python **static contracts** pass in isolation and the full suite. They check
selected source call boundaries, native-test inclusion, timer scheduling shape and PQ
argument guards. They do not execute Emacs or establish responsive GUI behavior.

The candidate supplies **150 ERT cases, including 26 new**. The new cases cover immediate
composer display, deferred/stale-account/rapid-selection callbacks, property-only row
selection, preserved drafts, bounded long text, paged originals, no decoder/decryption
on render, one visible preview per tick, no forced redisplay, and diagnostic redaction.
A native fixture uses a genuine delayed loopback server plus the actual Python read
worker, and asserts heartbeat progress, one GET, read=0, draft retention and bounded
rendering of a 200,000-character record. A separate actual child-process fixture uses
fake pqenv output to test asynchronous lifecycle, not signature/crypto correctness.
**None of these ERT cases was executed here: Emacs is absent.**

The retained 313 passing Python cases include real HTTP/worker processes, bounded
responses/deadlines, no automatic resends, original-file preservation, isolated Git
transactions, launcher protections, audit/report guards and real FFmpeg fixtures.
Their successes must not stand in for the 26 unexecuted new native regressions.

Development logs remain under `evidence/`: an early short-timeout invocation was
interrupted; a structural check exposed a new-test delimiter/cleanup-shape error,
which was corrected; a development audit overlapped source editing and correctly
failed source integrity. Only the later identical-code double audit is reported above.
No failing assertion was removed or converted to a skip. Package download attempts
could not obtain native tools; `native-tools-attempt.log` records DNS failure.

## Distribution and install gate

The full bundle is retained RC7 plus RC8. Its manifest carries explicit recorded older
compatibility hashes and exact new payload hashes. Current Codeberg/GitHub HEAD and
unrecorded variants are not asserted compatible. Normal update preserves .env, session,
optional independently newer pqenv source, and untracked unrelated data.

All **12** checks in `evidence/package-validation.json` passed: baseline integrity,
managed/full-source equivalence, RC7 preflight, delivered/audited code equality, staged
state exclusion and independent PQ preservation, transactional application/exact
rollback, unknown edits, newer-edit rollback refusal, corrupted payload refusal, and
review patch application/reversal. An initial assembly duplicated compatibility
anchors; the verifier refused it before any transaction. The assembly logic was
corrected and the complete check set rerun; the failed attempt remains recorded. Low-level file transaction tests
are labelled as such; they are not a successful native installer run. The production
Guix/update entry point retains its exact-candidate **two full-audit** gate with no bypass.
This iteration does not claim a new successful installed-native acceptance test.

Checksums prove consistency against this delivered bundle, not a maintainer signature
or an independent security attestation. Prose and evidence are not native execution.

## Remaining acceptance

Run the normal full native gate on the Guix machine and restart the Emacs instance.
Confirm `3.2.0-rc8` via the new diagnostic before testing the same contacts. Live freeze
backtraces, mouse/scroll behavior, native image decoding, real pqenv cryptography, mpv
windows, microphone capture and recipient delivery remain unverified. Explicit Sync,
Connect, QR and some legacy operations can still block; this patch is not an arbitrary
whole-process latency guarantee.

No VPS access, remote commit/push/tag/release, pairing change, service restart, live
WhatsApp message or retry of the previously declined CI write occurred. The Guile
bridge, wuzapi and PQ implementation are unchanged from RC7.

## Primary implementation references

- GNU Emacs synchronous processes: https://www.gnu.org/software/emacs/manual/html_node/elisp/Synchronous-Processes.html
- GNU Emacs idle timers: https://www.gnu.org/software/emacs/manual/html_node/elisp/Idle-Timers.html

These references explain blocking/timer semantics, not proof that this patch passes
native tests. See `CONTACT-SELECTION-3.2.0-rc8.md` for update, diagnostics and rollback.

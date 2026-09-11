# RC16 — executed review, not verified live phone delivery

## Release decision

Candidate. Both complete full-scope controller runs returned **1** with
6 PASS, 1 PARTIAL, 21 BLOCKED
and 0 FAIL gates. Each Python run discovered 548 tests:
**464 passed, 84 skipped, zero failures/errors**. The skips
require Guile and are not successful native integration. Emacs, Guile, fish, mpv
and Cargo are absent from this preparation environment.

The requested full live validation is not established. No user account, profile
photo, recipient, provider setting, actual service or remote repository was accessed
or changed. The historical provided reports name an older runtime and a failed
RC11-era temporary candidate; they do not establish installed/active RC15 or RC16.

## Baseline and exact scope

SHA-256-verified complete RC15 archive:
ad1b89568784815666ebc17a9ee479e24014cdea82c644086b0fe0a3a2b94305.
All 513 original internal checksums were checked. Current remote HEAD is not asserted
identical. Original late-account/transport regression source remains byte-identical.
The changed old face assertion still checks actual row hover behavior, now against
the explicit face object rather than an obsolete bare face-symbol expectation.

## Code findings and implementation

1. Profile worker nonzero exit discarded its structured failure body before updating
   the UI. Safe allowlisted failure categories now survive; nonzero output can never
   publish a ready image. This makes failures diagnosable; it does not prove that a
   real missing photo was caused by a specific category. Per-contact retry preserves
   consent and other metadata. Converter, provider, network and policy failures have
   bounded descriptions without free-form provider error strings or URLs.
2. Disabling local hl-line did not remove a separate global hl-line overlay already
   attached to this buffer. Cleanup now verifies overlay ownership and removes only
   that current-buffer global overlay. Row and hover faces explicitly set line/box
   attributes to nil. Tests supply repeated property updates and unrelated-overlay
   preservation; the exact graphical artifact has not been reproduced here.
3. History rows with sender_jid="me" but empty data_json lost own-message ownership.
   The inspected wuzapi outgoing-history helper uses that shape. RC16 preserves it
   while an explicit Info.IsFromMe=false remains authoritative. This repairs one
   history-normalization case, not live forwarding or all account-identity mappings.
4. The About API was given bare phone keys although the inspected /user/info contract
   parses full JIDs. Phone JIDs are now qualified and LIDs stay unchanged. This is not
   an avatar host-policy change or an inferred phone mapping.
5. New normal-text requests use /send/verified and require recipient_contract=1 plus
   an exact canonical accepted_chat. A mismatched LID/phone acknowledgement remains
   uncertain; an old bridge produces an activation error and no legacy fallback
   POST. This confirms agreement with the bridge only. Provider acceptance and real
   recipient delivery remain different. Legacy /send output/usage remains available.
   Explicit phone/phone-JID/LID/group identifiers are allowed (including leading +
   for phone input); friendly names and unsupported namespaces are not guessed.
6. Provider rejection HTTP categories reach safe local UI descriptions. Requests
   are not retried, arbitrary error bodies are not relayed, newer drafts and original
   late-account checks are preserved. Attachments/PQ do not gain a new delivery claim.

No CDN/address/TLS, image size, cache, timeout, source-update, account/privacy, replay,
receipt-authentication or double-audit restriction is loosened. No native Pale binding
is added and no selected player is silently replaced. No global theme/init change.

## Final execution evidence

- Pass 1: 2f15c03dbfcb46bf808e30d1de13b3d7, 2026-09-11T00:16:23.878298+00:00.
- Pass 2: c8a842ae9f73496e8037de59f280c252, 2026-09-11T00:17:24.545130+00:00.
- All **93 code/build hashes** are identical before/after both runs.
- **20 new executable Python tests pass**, including actual child processes and
  loopback HTTP for recipient agreement, no retries/fallback, invalid identifiers,
  legacy compatibility, and safe errors. A genuine FFmpeg raster conversion passes.
  Profile conversion/provider failure injection is explicitly mocked where needed;
  it does not constitute a real CDN/provider test.
- **234 ERT cases supplied**, including 14 new: not executed here. They cover send
  route/error/draft behavior, nonzero-worker status, account-preserving retry, explicit
  flat faces and actual overlay ownership. They are required in the native audit.
- **7 new Guile HTTP cases and 4 unit assertions** are supplied, not run here. Unit
  failure counting occurs after the new assertions. No test is silently excluded
  from the audit's native invocation.
- Baseline full audit and intermediate attempts are retained as development evidence,
  not final results. Final results reside in evidence/audit-pass-1 and audit-pass-2.

A native package download was attempted from the official Debian package page. The
web fetch could not parse the binary and the container download failed; no native
runtime was acquired. Structural Lisp checks are not compilers or interpreters.

## Development findings retained

Initial targeted tests exposed a fake-opener signature/shadowing error and a fixture
that incorrectly expected domain HTTP failure to force a worker process failure.
The mocks were corrected and malformed JSON used for the actual failing-process
case. No production assertion or retry policy was relaxed. Native-test structural
checks caught excess closing delimiters. Review corrected the global-highlight test
to account for its buffer-local variable, and placed the new Scheme assertions
before capturing failure count. Intermediate audits overlapping those edits properly
failed source-integrity. Only the later identical-source runs above are final.

## Distribution tests and live limits

See evidence/package-validation.json for the separate low-level update/rollback
fixtures, unknown-edit/refusal checks, patch application/reversal and actual read-only
preflight. Those tests do not bypass the production native gate or prove the app is
fully installed. A separate invocation of the real guarded updater (non-root UID 1000, no restart
option, no native gate mocks) completed both full audits. The activation report
remained at auditing-and-installing with installed=false and restart_attempted=false.
All **182 existing fixture files stayed byte-identical**, with zero installation
backups. This preserves synthetic private settings, session data, compiled bytecode
and an independently changed PQ source file. See evidence/native-install-refusal.json.
Its staged code equals the final managed code; two audit documents were added after
that invocation. The independently modified PQ audit input was deliberately retained.
Code hashes in the final package must match the two final receipts.

Normal update preserves .env, session files, personal init and independently newer
PQ source. It uses explicit recorded before-hashes rather than fuzzy patching or
replacing all of source/. Both native audits are required before file replacement.
The existing activation wrapper cannot restart a service after a failed update.
The complete client and bridge must both be activated for verified sends. Saved
hashes/reports are consistency checks, not signatures or independent attestations.

No measured GUI-speedup, full provider compatibility, real media loading or phone
delivery is claimed. After successful native tests, verify the runtime and loaded
client version, inspect one contact's Photo: label, and conduct one explicitly chosen
message test with a consenting recipient. Do not resend all previous uncertain
attempts. Callback registration is not a callback network-reachability test.

## Primary references inspected

- https://raw.githubusercontent.com/asternic/wuzapi/main/handlers.go
  (/user/info and saveOutgoingMessageToHistory; public upstream, not installed version)
- https://raw.githubusercontent.com/asternic/wuzapi/main/wmiau.go (recipient parsing)
- https://raw.githubusercontent.com/emacs-mirror/emacs/master/lisp/hl-line.el
  (distinct local/global overlays and ownership)
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Face-Remapping.html

References explain contracts. They do not prove that these native changes ran here.

## Final package checks

All 12 package checks passed: full-source/payload equality; real read-only preflight;
low-level application and exact rollback from recorded RC10/RC11/RC13/RC14/RC15;
unknown edit and newer-edit rollback refusal; original regression preservation; and
review patch application/reversal. No full-source copy replaces the user's live tree.
The final archive is re-extracted and all checksums, managed payload hashes and the
same 93 audited code fingerprints are verified separately. This is integrity evidence,
not a claim of native/live correctness.

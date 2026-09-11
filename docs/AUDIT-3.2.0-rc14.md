# RC14 — focused stale-send warning repair

## Decision and basis

Candidate, not native/live validated. The user reported the same sole failing ERT
identifier in both RC13 audits: `wa-rc3-late-send-after-account-change-retains-draft`.
The pasted result says installed files were unchanged. The following separate
Shepherd restart therefore restarted the previously installed files, not the
failed temporary candidate. No RC13 detailed ERT traceback was uploaded in this turn.
The older uploaded RC11 report has a different failing test and is not reused as
RC13/RC14 execution evidence.

The retained RC13 archive was SHA-256 verified and all 464 internal checksums passed.
Archive SHA-256: `703105e13bf47468aac7a4edecf88d1605736fcd4d7ff0351b0e4759a3c61941`.
Current remote HEAD, user working tree and running process were not accessed.

## Source-level diagnosis and exact correction

The retained test checks both preserved draft text and non-nil
`whatsapp--last-error`. RC13's stale-account/conversation branch marked the note
unconfirmed and hid its overlay for the other account, but omitted that error
assignment. The RC11 predecessor did set an error when the account no longer
matched. RC14 restores a constant, nonsecret warning in production code. The
original `tests/responsiveness-tests.el` and its assertion are unchanged byte for
byte. This is a source-grounded diagnosis consistent with the named failure, not
a claim of locally executed ERT or a reproduced native traceback.

No identity predicate, send payload, recipient target, strict ID acceptance, draft
clearance condition, retry policy or account isolation is relaxed. No request is
added. Six new ERT cases cover changed tokens/URLs, draft/point/marker/reply/undo
preservation, newer edits, redacted errors, duplicate replies, owner-buffer
isolation, unconfirmed resend refusal and ordinary successful acknowledgement.
The production behavioral patch is the missing error-state assignment. Other code
edits are release labels, a dynamic installer completion label, publication branch
metadata and regression tests. The original production audit gate is unchanged.

## Actual completed audits

Two final full audits, using `/usr/bin/python3` and a system-first PATH, returned
exit 1. Each: **6 PASS, 1 PARTIAL, 20 BLOCKED**. Each Python suite discovered **466**:
**389 passed, 77 skipped, zero failures/errors**. All skipped cases require Guile.
The skips are PARTIAL, not native passes. The existing structural Lisp, media
capability and synthetic benchmark checks passed; they do not execute ERT.

- First final run: `c4bcfa85e7f4422b9256841fd797d452`, report UTC `2026-09-10T20:47:10.464846+00:00`.
- Second final run: `3dfbf0b2853e42819e37a26388a62dbf`, report UTC `2026-09-10T20:47:58.127920+00:00`.
- All **88** code/build fingerprints match before/after both runs and final code.
- **216 ERT cases supplied, 6 new: not run here**, because Emacs is missing.
- Guile, fish, mpv and Cargo gates are likewise blocked. No dependency or operating
  system issue on the user's machine is inferred from their absence here.

An initial complete pair is retained under `evidence/development`. Its executable
checks also completed, but an obsolete RC13 completion-message label was corrected
afterward. Only the second frozen-code pair is final. A streaming execution-tool
attempt was unsupported and a runner initially referenced a not-yet-created log
directory; neither is counted as a test execution. No failing test was deleted,
converted to a skip, or given a relaxed timeout to obtain the reported outcomes.

## Packaging and activation

The cumulative manifest keeps explicit recorded earlier hashes and adds the exact
RC13 hashes. Unknown edits and unrecorded candidate variants remain refused. Full
source is for reproduction or new installations, not blind copying over an active
tree. Normal update retains .env, session data, the user's init and independently
newer PQ source. The supplied command places restart after successful two-pass
installation and explicit verification of all installed managed file hashes.

Package checks in `evidence/package-validation.json` are low-level transaction,
patch and consistency tests. They are not a successful native installation or
proof of a live service restart. No actual user service, callback, setting, Git
remote or WhatsApp account was touched. Checksums are integrity checks, not a
maintainer signature or protection against same-user source/evidence replacement.

## Remaining acceptance

Run both full native gates through the updater on Guix. Only after success verify
installed files, restart the already-identified local bridge, and fully restart
Emacs/its daemon. Do not resend previous uncertain attempts automatically.
Confirmed provider acceptance is not recipient delivery. Photos, presence,
callback reachability, GUI behavior and real delivery remain separate acceptance
checks. Pale remains unfinished; no new player, UI redesign, cryptography or
performance claim accompanies this repair.

Primary reference consulted: GNU Emacs ERT should semantics,
https://www.gnu.org/software/emacs/manual/html_node/ert/The-should-Macro.html .
The manual explains assertions, not evidence of this program's native correctness.

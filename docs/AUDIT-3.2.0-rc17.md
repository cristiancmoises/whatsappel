# RC17 — focused invalid-response handling repair and actual validation

## Scope and diagnosis

The baseline is the verified complete RC16 archive (not the unfinished RC16 review).
The operator's pasted native output names only
`whatsapp-workspace-send-failure-retains-draft-and-reply` in both ERT runs. Their
activation report says installed=false and restart_attempted=false. The exact
native ERT traceback was not supplied; no earlier RC11 trace is reused here.

The original test explicitly calls the send callback with `(200 . :invalid-json)`.
The strict acceptance predicate rejects this. RC16's warning formatter then uses
`(assoc "error" (cdr result))` on that non-list sentinel. The RC17 production
change checks `proper-list-p` before accessing an error association. `cdr-safe`
handles absent outer data. The existing five-message allowlist and constant
fallback stay unchanged. This is a source-grounded diagnosis; native execution
is required to confirm the complete path on the user's machine.

Draft text, newer edits, reply state, recipient identity, account separation,
strict provider-ID acceptance, success-only history refresh and no-resend policy
are preserved. Original `tests/workspace-tests.el` and
`tests/responsiveness-tests.el` are byte-for-byte unchanged. No failure is deleted,
marked expected, or skipped to allow installation. No new arbitrary error text
is displayed. The new guard does not turn invalid data into acceptance.

Runtime code outside this guard is unchanged, apart from release labels. Publishing
metadata and its test version are updated; the source installer, activation helper,
Guile behavior, wire contracts, Python workers, profile pipeline, UI styling and
media preference are unchanged. This does not fix or verify live phone delivery,
Pale playback, private photos or callback reachability.

## Actual execution

Both full audits completed with exit 1. Counts per run:
{'PASS': 6, 'PARTIAL': 1, 'BLOCKED': 21}. Each Python run discovered 548 tests:
464 passed, 84 skipped, 0 failures,
0 errors. All skips require Guile. Source consistency covers
93 code/build files; all before/after maps match both runs
and the delivered code.

Pass 1 run ID: 8f7d1340c2144035820d3c9522232d21; completed 2026-09-11T01:17:48.524069+00:00.
Pass 2 run ID: ed77b45ada964aefb3c5a439138a376f; completed 2026-09-11T01:18:58.726810+00:00.
Baseline audit was also executed, separately labelled.

**Emacs, Guile, fish, mpv and Cargo are unavailable in this preparation runtime.**
The public Debian package was located using web tools, but DNS/binary transfer
could not retrieve a runnable package. No native results are inferred from that
lookup. The supplied 244 ERT cases (234 retained + 10 new) are NOT reported as
executed. A Lisp structure scan is not an Emacs reader/compiler or ERT run.
The source and callback fixtures contain no real user credentials or contacts.

New native coverage: immediate/deferred invalid JSON, scalar and empty failure
bodies, allowlisted and untrusted error fields, newer draft/reply/point/marker/undo
preservation, duplicate callbacks, no resend, correct owner buffer, closed buffer,
late account changes and ordinary valid acceptance. Fixture sends replace transport
with callbacks; these are not provider-delivery tests. Existing Python suites
exercise real local workers, HTTP, FFmpeg, file guards and process lifecycle.

## Package and installation safeguards

The cumulative package preserves explicit recorded old before-hashes and adds the
exact RC16 hashes. It is not a fuzzy patch or copy-over of the full source. Final
package checks separately cover source/payload/audit-hash consistency, unchanged
original regressions, prior-version application and exact rollback, independent
config/session/PQ preservation, unknown changes, tampering and patch round trips.
Low-level file transactions are not a native installation. See
`evidence/package-validation.json` for executed results.

The unchanged installer stages the target's own retained inputs and requires TWO
complete exact-source audits before replacement. The unchanged activation helper
cannot restart after failed installation. The actual non-root installer-refusal
exercise is recorded separately in evidence when completed; no mocked native gate
or fake passing receipt authorizes this distribution.

Native ERT, the actual Guix environment, service activation, graphical appearance,
physical microphone, real CDN/provider data, messages/receipts and current dependency
advisories remain separate and unverified. No user's service or repository was
changed. Do not resend previous uncertain attempts. Restart Emacs only after
successful installation/activation and retain the printed backup/rollback command.
SHA-256 provides distribution consistency, not a maintainer signature or security
certification. The developer container's date is recorded by the actual audit tool;
user timestamps remain separate observations.

Primary reference: GNU Emacs Lisp Manual, List-related Predicates / Cons Cells,
https://www.gnu.org/software/emacs/manual/html_node/elisp/List_002drelated-Predicates.html
and GNU ERT should semantics,
https://www.gnu.org/software/emacs/manual/html_node/ert/The-should-Macro.html .
These describe list/assertion behavior, not execution evidence of this candidate.

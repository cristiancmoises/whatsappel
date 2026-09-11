# RC13 — executed repair audit, not a live-delivery guarantee

Prepared 2026-09-10. **Candidate.** Two full-scope runs on the declared system
Python returned **1**, each with **6 PASS, 1 PARTIAL, 20 BLOCKED**. Native Emacs,
Guile, fish, mpv and Cargo are unavailable here. No user account, message, live
provider, GUI frame, remote repository or actual service was accessed or changed.

## Source and operator evidence

The RC11 archive SHA-256 is
`3f25aa457f2b40926e1ff7bb03895614cdd26545f1d4098bed6b3e6a6f378fe9`.
All 428 baseline file checksums were verified before editing. The operator's latest
candidate audit contains 87 code fingerprints; every one matches that retained RC11.
It reports 462 Python passes with zero skips and a single failed ERT identifier:
`wa-rc3-get-uses-worker-post-retains-url-transport`. The other native/bridge gates
passed on the operator's machine. Those are RC11 observations, not RC13 test results,
and an audited candidate is not necessarily the installed or running code.

`evidence/diagnosis.json` records the matching counts, failure identity and exact
old/new target function bodies without publishing private contacts or raw traces.
Current Codeberg/GitHub HEAD and undocumented RC3/RC9 variants are not assumed
identical. The incomplete RC12 review/diagnostic work is not the source baseline.
The cumulative update keeps explicit earlier hashes and refuses unfamiliar edits.

## Findings and changes

The client stripped every JID suffix except @g.us. That turns `123456789012345@lid`
into bare digits before its worker sends the request. The inspected public wuzapi
parseJID uses the telephone namespace for bare digits, while the existing Guile
history key preserves @lid. Thus the wrong transformation can change both provider
destination and local conversation storage. RC13 preserves @lid, groups and opaque
qualified identities, normalizes only explicit old phone suffixes, and recomputes
the text target from the actual selected JID. No speculative identity mapping,
old-message migration, session deletion or automatic resend is implemented.

The ERT failure is a stale contract fixture: /send now uses the strict worker and
supplies an optional third payload argument, while the old mock expected only two
arguments and URL transport. The same test ID now verifies snapshot GETs, explicit
/send payloads and unrelated legacy POST routing. No production send security is
reverted and no failed test is deleted or converted to a skip.

Normal text sends now display bounded in-memory local notes for Sending, Accepted
awaiting history/receipt, and Unconfirmed. One owned overlay preserves buffer text,
draft markers and undo positions. Only same-conversation own history records with
matching provider IDs retire accepted notes. No wire ID or delivery receipt is
invented. Unknown outcomes keep drafts; repeating the same uncertain text requires
explicit review/dismissal. Limits are 16 notes / 256 KiB raw text, with bounded
120-column previews. These are not persisted after buffer closure. Media/PQ status
workflows are unchanged; new local notes apply to ordinary text.

Buffer-local face remapping removes inherited decorative lines and boxes; local
line-number/fill/hl-line guides are suppressed. Background selection and hover
remain. Toolbar actions wrap to their window width. No global theme, user init,
Centaur/tab-bar setup, unrelated overlays or editor buffers are overwritten.
The exact user's visual artifact has not been reproduced in a graphical frame.

## Executions on identical code

Final system run 1: `d6435700691447fdbd4afa06278575b6`; report UTC `2026-09-10T20:08:39.609698+00:00`.
Final system run 2: `a7670aae15e24bd69f43f60d68fe5403`; report UTC `2026-09-10T20:10:08.108464+00:00`.
All **88** code/build fingerprints match before/after both runs and the candidate.

| Gate | Both system-Python runs |
|---|---|
| Python suite | PARTIAL: 466 discovered, 389 passed, 77 skipped, zero errors/failures |
| Structural Lisp checks | PASS, not an Emacs/Guile interpreter/compiler |
| JSON/envelope and thumbnail benchmarks | PASS, retained algorithms, no RC13 speedup claim |
| FFmpeg capability check | PASS; retained suite also uses real synthetic encoding |
| Source integrity | PASS; same 88 code/build inputs |
| Emacs compile/ERT/two native benchmarks | BLOCKED: missing Emacs |
| Seven fish entry-point checks | BLOCKED: missing fish |
| Guile unit and four HTTP suites | BLOCKED: missing Guile |
| mpv decoding | BLOCKED: missing mpv |
| Rust tests/format/Clippy | BLOCKED: missing Cargo |

The 77 Python skips are Guile-dependent integration cases (75 retained plus two
new). The two new executable Python cases run actual child workers against local
HTTP fixtures, proving unchanged qualified recipient bytes and one request per
explicit attempt at that worker boundary. Together with the retained delivery
suite, **34 targeted cases passed**. This is not an Emacs target-function runtime
test, a live provider send, or phone delivery.

**210 ERT cases are supplied, including 17 new ones. They were not executed here.**
New coverage is specified for target namespaces, stale target variables, single
send/callback handling, unconfirmed-duplicate refusal, authoritative-ID reconciliation,
account changes, newer draft preservation, one-overlay reuse, byte/count bounds,
explicit clearing, local theme isolation and 200 selection updates without inserted
characters. Two additional native Guile cases verify LID storage and receipt
separation from a phone with the same digits; they were skipped, not passed.

## Retained failures and interpreter measurements

An early full audit invocation was interrupted by the execution-tool timeout and
has no completed receipt. Its partial logs remain under evidence/pass-1. The first
completed pair used /opt/pyvenv/bin/python3 and failed two unchanged wall-clock
read-worker deadline tests. They returned the correct nonzero/deadline result but
exceeded the 2.5-second end-to-end budget (about 2.9 seconds). Those full reports
remain under evidence/final-pass-1 and final-pass-2; their directory names do not
make them the final release decision.

A separate empty-process measurement observed roughly 1.89–2.02 seconds for that
interpreter and 0.047–0.070 seconds for /usr/bin/python3, both Python 3.13.5. The suite
was rerun twice using the already installed system interpreter and /usr/bin-first
PATH. **No deadline assertion, security check or application source was relaxed.**
The unchanged deadline tests passed in both system runs. Raw samples are in
interpreter-startup.json. This is an environment comparison, not a WhatsApp speedup.
The slow-interpreter failures remain relevant when choosing a real runtime.

Native package retrieval was attempted but unavailable through the permitted
network/tool path. No denied CI operation was retried and no substitute native
success was invented. No new whole-app latency/RSS or native graphical measurement
is claimed; original benchmarks remain separately labelled synthetic.

## Packaging and installer safeguards

See evidence/package-validation.json for actual checksum, full-source/payload,
RC10/RC11 apply-and-rollback, unknown-edit refusal, tamper refusal, newer-edit
rollback refusal, patch round trip and check-only results. Direct apply_files
fixtures deliberately test low-level transactions, not native application validity.
Any actual installer-refusal run is recorded separately and must not be interpreted
as a successful install. The production two-pass gate, source fingerprints, private
backups, immutable payloads and refusal rules are unchanged.

The full package retains independently newer operator PQ inputs for tests and does
not overwrite .env, sessions or unrelated data. Final docs/evidence are assembled
after code testing; extracted delivered code must still match both system receipts.
Checksums show internal consistency, not a third-party signature or protection
against an attacker who can rewrite source and receipts as the same user.

## Remaining acceptance

Run the normal guarded update on the user's Guix machine, then restart the actual
bridge and Emacs only after success. Confirm loaded RC13 before selecting a LID
conversation. Inspect one intentionally sent test with a consenting recipient;
never auto-retry previous uncertain attempts. A corrected target does not repair
unreachable webhooks, missing privacy permissions or expired attachments. Pale is
still unfinished; this patch does not advertise it as working. No idle inference,
new crypto promise, VPS action, push, session reset or live message was performed.

Primary references inspected:
- https://raw.githubusercontent.com/asternic/wuzapi/main/wmiau.go (parseJID, upstream not installed build)
- https://raw.githubusercontent.com/emacs-mirror/emacs/master/lisp/button.el (button face/insertion semantics)

References explain contracts, not proof that this native application passed.

## Final package and actual installer-refusal execution

Ten package/transaction checks passed after adding the final documents. They include
exact RC10 and RC11 transactions/rollback, payload tamper and unknown/newer edit
refusal, a real check-only invocation, review patch round trip and delivered-code
equality to both system-Python audits. All 44 Python source files compile without
execution; this does not substitute for the unavailable native languages.

A separate actual guix-workflow.py invocation on a disposable RC11 tree ran both
full audits with the unchanged production gate. It returned 1, left all 162 existing
fixture files byte-identical and created zero installation backups. The gate was
not mocked. Synthetic .env/session data and independently changed PQ source were
preserved. See evidence/native-install-refusal.json. This is a successful refusal,
not a successful native installation or claim of real provider connectivity.

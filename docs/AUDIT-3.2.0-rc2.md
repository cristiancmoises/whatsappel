# WhatsAppel 3.2.0-rc2 — executed audit and release gate

Prepared for 2026-09-09 (America/Sao_Paulo). Final full audit runs ended at
2026-09-10T02:11 and 2026-09-10T02:15 UTC. See each report for its exact timestamp.

## Decision

**Release candidate; native and live acceptance is incomplete.** Both full audit
runs returned exit code **1**, not success. Each recorded 3 passing gates and
15 blocked gates. Native Emacs, Guile, fish, mpv and Cargo were not installed in
the preparation environment, and attempts to obtain their packages failed.
Python or a delimiter scanner is not a substitute for those runtimes.

The installer runs the selected candidate checks twice before writing installed
source. Missing tools and failed gates stop installation; no bypass flag is
provided. Full scope additionally checks the retained Rust component. The delta
changes both the Emacs client and Guile bridge. Restarting their actual running
instances is necessary after a successful installation.

## Source provenance and boundaries

The baseline is the retained 3.1.0 source overlaid with the previously delivered
3.2.0-rc1 managed payload. GitHub main was read through the connected GitHub
connector. At inspection, its tree was
`1c74c2fde6acbe7409c9e372767413dc280b6970` and these blobs matched the reconstructed
rc1 baseline exactly:

| File | Git blob SHA-1 |
|---|---|
| whatsapp.el | 0f0db9999380d6a08aa9b71059fdd800c9a75d0e |
| whatsappel.scm | 9ba03a6dc039ac9f1d3f71794a4444e92514b70e |

Current Codeberg HEAD and a complete current-mirror snapshot were **not** verified.
The mirror has independently newer pqenv work. This is a per-file content-anchored
delta, not a replacement repository; it does not ship a pqenv replacement or
change wuzapi, configuration, pairing state, network ports, NPM, or credentials.
The native audit candidate copies unchanged inputs from the destination checkout.
The local fixture's retained Rust source is not asserted to be current upstream.

## Double audit: actual results

The source-code fingerprint maps in both full reports are identical. Each Python
run discovered **108 tests: 84 passed, 24 skipped, 0 failed**. Fourteen skips are
the retained Guile HTTP suite and ten are the new Guile read/media API suite.
These skips also have independent BLOCKED gates; they are not counted as passes.

| Gate | Pass 1 | Pass 2 |
|---|---|---|
| Python regression suite | PASS, with the 24 declared skips | PASS, with the 24 declared skips |
| Structural Lisp checks only | PASS | PASS |
| FFmpeg capability checks | PASS | PASS |
| Emacs byte compilation | BLOCKED | BLOCKED |
| Emacs ERT, 66 cases supplied | BLOCKED | BLOCKED |
| Native Emacs layout benchmark | BLOCKED | BLOCKED |
| mpv local decoding | BLOCKED | BLOCKED |
| Five fish syntax gates | BLOCKED | BLOCKED |
| Guile unit tests | BLOCKED | BLOCKED |
| Original Guile HTTP integration | BLOCKED | BLOCKED |
| New Guile read/media API integration | BLOCKED | BLOCKED |
| Rust tests, format, Clippy (three gates) | BLOCKED | BLOCKED |

Logs and source SHA-256 maps are in `evidence/audit-pass-1/` and
`evidence/audit-pass-2/`. Each report's `passed` field is false. The structural
checker only examines balanced forms and selected binding/body shapes; it does
not implement the Emacs reader, Guile reader, byte compiler, or ERT evaluator.
No graphical screenshot or native performance number is fabricated.

### Executed Python and external-process coverage

The 18 added Python cases cover 14 read-only diagnostic regressions and four
isolated-launch regressions. Diagnostic tests use actual local HTTP servers:
credential/destination validation, refusal of redirects, bounded response reads,
old-bridge read avoidance, read=0 on v2, conditional requests, anonymized reports,
private new-only output, malformed responses, and no message POSTs. Quick launch
checks the actual argv construction and refusal to lose init-only credentials.
These are not tests of the Guile implementation or graphical Emacs startup.

The retained suite also executes actual attachment-worker subprocesses against
loopback HTTP, original-byte preservation, error/redirect/no-automatic-resend
paths, real FFmpeg GIF-to-MP4 and synthetic Opus encoding, safe extraction and
installation transactions, and isolated Git worktree/commit fixtures. A native
installer gate is deliberately mocked only within the retained transaction/
publication-isolation fixture. That mock does not establish native validity.

The final package contains additional `package-validation.json` evidence for
patch apply/reverse/hash equivalence, manifest preflight, staged unchanged-code
preservation, altered-file refusal, rollback and real blocked installation.
Those checks validate packaging and guard behavior, not live functionality.

### Supplied but unexecuted new native regressions

Twenty added ERT cases cover bounded window paths, unchanged/bad/stale-account
responses, legacy compatibility, Load older, retained draft/marker/undo on tail
updates, sliding-window single insertion, edit/deletion, 80-row roots, searching
beyond the first page, control-character flattening, unread navigation, retained
forward keybinding, name indexing, property-only preview updates, one media POST,
busy-pool handling and polling backoff. Together with 46 retained ERT cases,
66 ERT tests are supplied, not claimed executed.

Ten new Guile HTTP integration tests cover v2 health, bounded read-only windows,
invalid limits, revisions, window expansion, explicit mark-read semantics, old
array routes, slow downloads versus chat-read latency, two-slot saturation and
authenticated single-consumer results, and invalid-media rejection. Their slow
upstream test is a genuine native integration test, but it was skipped here
because Guile is absent. Its latency assertion is not a measured result.

## Findings and implemented changes

The old client requested entire retained histories and the bridge rebuilt chat
summaries by scanning stored message lists on every chat-list read. The rc2 read
API supplies an initial 60-message window, cached summaries, and process-scoped
revision responses that omit unchanged record arrays. The old route shape is
retained. Serialization moves outside the store mutex; mutation paths invalidate
cached snapshots. Name updates are now protected by the store mutex as well.

The main HTTP server previously performed normal media downloads synchronously.
The new client submits one authenticated media job and polls it, while up to two
workers perform that validated upstream work. Completed results are single-use
and expire after 60 seconds when uncollected. No token/redirect/CDN validation is
disabled and no additional listening port is introduced.

The native UI now bounds initial root rendering to 80 compact two-line rows,
searches all cached rows, indexes names, displays cached chats before refresh,
and reduces repeated message action controls. Tail/sliding-window updates avoid
recreating the draft. Image completion updates a placeholder's display property
rather than erasing the transcript. Normal initialization remains available;
explicit --quick uses Emacs -Q only with separately available credentials.

These are implementation changes with bounded work, not measured speedups.
No end-to-end loading time, FPS, GUI-memory ceiling, or improvement percentage is
asserted. The included read-only doctor measures HTTP latency/bytes on the real
installation. The supplied batch-Emacs benchmark separately measures synthetic
layout work when Emacs is available; neither proves recipient delivery.

## Security, compatibility and remaining risks

The new diagnostic does not send messages or mark chats read, and its JSON output
omits raw tokens, JIDs, names, texts, responses and URLs. Tokens are entered through
protected configuration/environment or a hidden prompt, not a CLI argument.
TLS verification and redirect refusal remain enabled. Checksums establish bundle
integrity against the delivered manifest, not a third-party signature.

The bridge remains single-account. Workers/results are bounded, but an upstream
request that never ends can retain a worker slot; Guile calls are not forcibly
cancelled. Legacy downloads, explicit Sync/Connect and other retained synchronous
operations can still block. Request bodies may be buffered before application
limits run; public deployment still requires appropriate ingress limits. Header
checks and restricted mpv arguments are not complete decoder sandboxes.

This is not a browser application or a complete telega implementation. Voice/GIF
routes retain their previous semantics, without new native WhatsApp PTT/GIF-loop
flags or new pqenv attachment encryption. Changes to settings/accounts while old
buffers exist require care; background callbacks reject changed origin scopes,
but the application does not claim a new multi-account UI or automatic account
history migration.

Actual graphical mouse actions, scroll behavior, image decoding/zoom, mpv windows,
physical microphone capture, WhatsApp pairing/delivery and synchronization,
IONOS service activation, all four remote pushes and current dependency advisory
checks were not executed. No assertion that everything works is warranted until
native tests and manual acceptance pass on the real configuration.

## Connected-account actions during preparation

One empty GitHub branch, `audit/chat-performance-rc2-20260909`, was created from
main. Authorization to write its proposed native CI workflow was declined; the
workflow was not written, run or retried. No rc2 source changes, tags or releases
were pushed. Main and production were not modified. No VPS connection/deployment
or live WhatsApp test message was performed.

## Reproduce safely

From the extracted bundle, with a complete matching rc1 checkout:

```fish
python3 scripts/update-package.py ~/whatsappel --audit-only --full-audit
```

The command stages a candidate and executes both full audit passes without
installing. Only proceed through the guarded installer after the native gates
pass. See `docs/PERFORMANCE-3.2.0-rc2.md` for read-only diagnostics, UI usage,
activation, rollback and the manual release checklist. This report is a scoped
developer review, not an independent security certification.

Primary implementation references consulted:
- https://zevlg.github.io/telega.el/
- https://www.gnu.org/software/emacs/manual/html_node/url/Retrieving-URLs.html
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Sticky-Properties.html
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Insertion.html
- https://www.gnu.org/software/guile/manual/html_node/Web-Server.html

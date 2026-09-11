# WhatsAppel 3.2.0-rc4 — executed validation report

Prepared 2026-09-10 UTC. **Release candidate, not production-certified.**
No source was pushed, no VPS was accessed, no service was restarted, no real
WhatsApp message was sent, and the previously declined GitHub workflow write was
not retried. This is an implementation review, not an independent security audit.

## Scope and provenance

The source is the retained 3.1 snapshot overlaid with retained RC1/RC2/RC3 payloads.
All 77, 65, 77 and 125 respective checksum entries were verified before packaging.
The current Codeberg/GitHub HEADs were not fetched or asserted. The cumulative
manifest accepts only recorded per-file hashes from these four retained baselines.
Local fixture Git commits are not upstream provenance. Unknown edits stop preflight.

There are **16 changed source/documentation files from RC3** and **57 managed
cumulative files**. `whatsappel.scm` is identical to the retained RC2/RC3 bridge;
no new wuzapi or pqenv source is delivered. Configurations, pairing/session data,
NPM, network ports and independently newer PQ work are outside the payload.
The standalone patch is RC3-to-RC4; the installer handles cumulative baselines.

## Implemented findings

The old depth prepass iterated over every response byte in Python, including long
plain text/base64 spans. RC4 uses simple non-backtracking character-class searches
for long spans and retains the byte-loop fallback on escape-dense input. The
fallback was added after an initial benchmark exposed a regression on dense
escapes; the unsuccessful initial optimization is not described as universally
faster. The nesting limit and strict JSON parser remain. Exponent overflow (for
example `1e309`) and malformed percent escapes in the read query are now rejected.

The root layout key previously included unread totals, so a count change caused a
complete bounded redraw. RC4 moves the summary update out of the layout key and
replaces only affected rows when order/filter membership is stable. Off-page unread
changes only update the summary. Actual order/filter/width changes still redraw.

The UI adds cache-only annotated switching (`C-c C-j`, root `j`, Switch button),
compact/detailed rows (root `d` or button) and Direct/non-group filtering. Switching
includes every cached chat and requires a known completion choice. The New command
still accepts a new number/JID. Density is buffer-local, preserves filters/query/page
limit, and has no silent persistence. Existing Forward and draft controls remain.
The stale `whatsapp-version` constant identifying RC2 in RC3 was corrected to RC4.

## Two complete full-scope controller runs

Both controller runs returned **exit 1**: **5 PASS / 15 BLOCKED** each. All checked
source fingerprints match before/after both runs, and match the delivered code.
An earlier attempt was interrupted by the tool timeout before its controller
finished; its partial log is retained under `interrupted-audit-attempt/` and is not
counted as a completed audit. `double-run-exits.json` records the final exits.

| Gate | Both final runs |
|---|---|
| Python regressions | PASS: 159 discovered; 135 passed; 24 skipped; zero failures |
| Lisp structural checks | PASS, not an Emacs/Guile reader or compiler |
| Read JSON benchmark/output equivalence | PASS; no speed threshold used |
| FFmpeg capability check | PASS; retained suite also exercises real conversion/encoding |
| Source self-integrity | PASS |
| Emacs byte compilation, ERT, native layout benchmark | BLOCKED: Emacs absent |
| Guile unit and two HTTP integration gates | BLOCKED: Guile absent |
| Five fish syntax gates | BLOCKED: fish absent |
| mpv local decoding | BLOCKED: mpv absent |
| Rust test/format/Clippy | BLOCKED: Cargo absent |

The 24 Python skips are Guile-dependent bridge tests, not passes. Native runtimes
could not be obtained in this environment (package-network/DNS attempts failed).
**108 ERT tests are supplied, including 17 new ones; none executed here.** No
structural check is substituted for byte compilation, actual ERT or GUI behavior.

The 20 new Python tests passed: 3,000 seeded JSON roundtrips inside one test, depth
boundaries through 96/97 levels, dense escapes and fallback thresholds, quote/
backslash parity, UTF-8 and controls, long spans, duplicate and escaped duplicate
keys, finite/exponent-overflow values, strict query encoding, and four actual
read-worker child/HTTP fixtures. The child fixtures check large JSON, chunked
escaped strings, excessive nesting and redacted overflow errors without retry.
They are not a test of real WhatsApp synchronization or recipient delivery.

The new ERT cases cover one-row unread updates, off-page counts, count-digit growth
and cursor position, no-op summaries, unread-filter changes, compact/detailed rows,
pagination, density/filter/query preservation, Direct filtering, switching beyond
the visible page, duplicate names, annotation bounds, cancellation/draft retention,
keybindings and version identity. These are supplied acceptance checks, not claimed
native results.

## Measured isolated parser cost

Final controller pass 2; Python 3.13.5; seven alternating samples per variant, same
synthetic bytes and equal parsed output. Times below are **median milliseconds**.
Full p95 and every individual sample are in `read-json-benchmark.log` in both audit
directories. The baseline function preserves the RC3 prepass/parser on finite
fixtures. No performance pass/fail threshold is used.

| Fixture | Input bytes | RC3 p50 ms | RC4 p50 ms | RC3 / RC4 |
|---|---:|---:|---:|---:|
| unchanged_snapshot | 53 | 0.051 | 0.052 | 1.00× |
| chat_list_1000 | 207,781 | 9.070 | 5.553 | 1.63× |
| text_4MiB_span | 4,194,283 | 162.587 | 22.544 | 7.21× |
| media_16MiB_span | 16,777,227 | 661.188 | 88.203 | 7.50× |
| escape_heavy | 960,011 | 34.013 | 33.869 | 1.00× |

The large-span measurements are not end-to-end loading improvements. Tiny unchanged
snapshots show no meaningful win, and escape-heavy data is approximately unchanged
in these runs after the fallback. First-run measurements and the initial/fallback
experiments are also retained. Python startup, networking, Emacs conversion, native
layout, image decoding and actual bridge work are excluded. No whole-app latency,
RAM ceiling, delivery rate, or universal speedup is asserted.

## Package/installer evidence

`package-validation.json` records cumulative check/apply/rollback fixtures for
3.1, RC1, RC2 and RC3, final hash equality, preservation of synthetic configuration/
session data and independently changed PQ source, newer-edit refusal (including
rollback), standalone patch apply/reverse, source fingerprints and installer refusal.
Low-level transaction fixtures call `apply_files` directly to isolate file handling;
they do not represent a passed native audit. No installer bypass is added.

The separate actual `update-package.py --apply --full-audit` invocation targets a
disposable RC3 source fixture, not the user's machine. It must complete both audit
passes, encounter missing native gates, exit nonzero, and leave that fixture's
files byte-for-byte unchanged. Its actual exit/verification appears in
`native-install-exit.json` and `native-install-refusal-verification.json`.

Final archive checks are provided in the sibling `whatsappel-3.2.0-rc4-package-verification.json`.
The archive checksum and internal hashes detect mismatch relative to this package;
they are not a maintainer/third-party digital signature. No current remote state
or full application correctness follows from successful patch/checksum tests.

## Remaining limitations and release decision

This remains the native Emacs architecture. One child process per read is still
used; a persistent read service was deliberately not introduced without native
lifecycle validation. Legacy synchronous operations and server-side bottlenecks
remain. The native UI features, viewport behavior, mouse click targets and draft
semantics must pass Emacs tests and manual checks before routine deployment.

Graphical Emacs, actual image/zoom and mpv windows, physical microphone/PipeWire,
QR pairing, Sync, recipient delivery, current dependency advisories, VPS activation
and four-remote publication were not tested. Voice remains the existing Opus-audio
route, GIF conversion remains the existing MP4 route, and ordinary attachments
have not acquired a new PQ/E2EE guarantee. No production certification is claimed.

Run the documented `--audit-only --full-audit` on the actual complete checkout.
Only a passing native installation gate permits file replacement. Keep the printed
backup, restart Emacs, and restart the existing bridge only from pre-RC2. Test real
media and delivery using explicitly approved account interactions before rollout.

Primary design references consulted (not evidence of implementation success):
- GNU Emacs asynchronous processes: https://www.gnu.org/software/emacs/manual/html_node/elisp/Asynchronous-Processes.html
- GNU Emacs sentinels: https://www.gnu.org/s/emacs/manual/html_node/elisp/Sentinels.html
- telega root/chat model: https://github.com/zevlg/telega.el/blob/master/docs/telega-manual.org

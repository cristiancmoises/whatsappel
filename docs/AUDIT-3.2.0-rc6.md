# WhatsAppel 3.2.0-rc6 — native-failure repair and executed audit

Prepared 2026-09-10. **Release candidate, not fully native/live validated.**
The two local full-scope audit runs returned **1**, with **5 PASS, 1 PARTIAL,
15 BLOCKED** each. The machine running this preparation lacks Emacs, Guile, fish,
mpv and Cargo. Package/reference download attempts failed. The operator's working
native toolchain is not remotely accessible through this uploaded archive.

## Exact diagnosis, not a guessed dependency problem

The uploaded RC5 archive contains two matching source fingerprint maps. All **62
code/build hashes** match the reconstructed retained RC5 candidate. Its reports
show 19 PASS and 2 FAIL per pass. ERT: 107 passes and 1 failure out of 108. Guile:
77 passes and 1 failure. Those are the operator's RC5 outcomes, not RC6 outcomes.

1. `whatsapp-workspace-bounded-history-and-expand` asserted the obsolete text
   `Show older`. The actual rendered control was `Load older`. RC6 identifies the
   actual command via button metadata, activates it, checks history expansion and
   draft retention, and checks that the control disappears once cached history
   is fully visible. No history-limit or application guard is removed.
2. `tests/bridge-tests.scm:118` used `(test-error "name" expression)`. In that
   two-argument form the string was treated as the expected error matcher, which
   caused the reported matcher exception. RC6 uses `(test-error "name" #t expr)`.
   It adds invalid-number/range and valid-boundary/default assertions, checks the
   configuration exception class separately, and restores the test environment.
   The production `env-integer` guard and bridge code are unchanged.

No test was removed or changed into a skip to resolve these failures. The old
polling fixture was updated to supply windows rather than mock a buffer scan;
it still verifies only the visible chat refreshes.

## Scoped improvements

The Emacs poller traverses visible frame windows rather than every buffer, excludes
minibuffers and hidden/iconified frames, deduplicates buffers, retains backoff,
and isolates synchronous refresh exceptions. New native regressions cover those
cases plus actual Return activation and wording-independent button identity.
This is a reduction in selected work, **not a measured native speedup**.

Launcher configuration is opened once with non-following/nonblocking flags, checked
using that descriptor, and read within 64 KiB. It must be a private user-owned
regular file. Duplicate recognized settings, invalid encoding, substitutions and
control characters are refused. Missing .env continues to support Emacs init.
Actual old/new synthetic-file comparisons show RC5 accepted a mode-0644 token file
and duplicate token assignments; RC6 rejects both and retains valid mode-0600
behavior. Tokens never appear in launcher argv or compact errors. This is not a
sandbox against a hostile process running as the same user.

The audit prints failed native test IDs/source lines without copying assertion
values or traces. `--summarize` reads existing reports without executing code,
ignores report-supplied log paths, bounds reads, refuses links/special files, and
rejects contradictory metadata. It preserves failure status. A saved report is
not an independent execution attestation or proof of authenticity.

## New full executions

Each Python run: **284 discovered, 260 passed, 24 skipped, 0 errors/failures**.
All 24 skips require the absent Guile runtime. This is correctly PARTIAL, not
PASS. The 48 new Python cases pass in both full runs and in a separate targeted
run. Tests exercise actual file descriptors, FIFOs, oversized files, ownership,
permission modes, malformed settings, redacted errors and read-only summaries.
The retained suite also runs actual child processes/loopback HTTP, deadlines,
no-resend behavior, file preservation, FFmpeg conversion and Opus fixtures.

| Gate | Both full runs |
|---|---|
| Python regression suite | PARTIAL: 260 passed, 24 Guile-dependent skips |
| Structural Lisp shapes | PASS; not a native reader/compiler/runtime |
| Read JSON and envelope benchmarks | PASS; retained algorithms, not an RC6 speedup comparison |
| FFmpeg capability checks | PASS |
| Source integrity | PASS |
| Emacs compile, ERT and layout benchmark | BLOCKED: missing Emacs |
| Guile unit and two bridge HTTP suites | BLOCKED: missing Guile |
| Five fish syntax gates | BLOCKED: missing fish |
| mpv decoding | BLOCKED: missing mpv |
| Rust tests, formatting, Clippy | BLOCKED: missing Cargo |

There are **118 supplied ERT tests**, including 10 new cases. They were not run
here. The Guile unit suite adds 13 assertions to its former 78-case source; native
execution is still required. A Python structural check cannot establish the
correctness of either native language or GUI behavior.

Both full runs have identical **64-file code fingerprints** before and after
execution. Their run IDs are 0f5085b488644031973a52493c86bfc3 and 245dde9859e0406d88da39b417e7a7c9; completed at 2026-09-10T12:04:53.892196+00:00 and 2026-09-10T12:06:35.141092+00:00.

## Development and packaging evidence

The first targeted launcher run exposed an `os.fdopen` directory error before
metadata validation. Validation was moved before wrapping the descriptor and
cleanup made explicit; the same directory test and entire 48-case targeted set
then passed. That earlier failing log is retained under `evidence/development`.
No failing test was discarded. Raw operator logs are NOT republished in this
bundle; `baseline-findings.json` and `user-log-diagnosis.txt` contain the relevant
hashes, counts and compact identities without raw assertion values.

See `evidence/package-validation.json` for cumulative compatibility, transactional
application/rollback, source preservation, unknown-edit refusal, tamper checks and
patch round-trip results. Low-level transaction fixtures do not establish native
application correctness. The full exact-candidate two-pass installation gate is
unchanged; partial, failed or missing checks cannot authorize replacement.
Documentation/evidence was finalized after code audits; delivered code hashes
must still match both reports. Current remote HEAD and unrecorded RC3 variants
are not asserted compatible. Checksums are integrity checks, not signatures.

## Remaining acceptance and external actions

No VPS access, deployment, live WhatsApp message, remote branch/tag/release/push,
new pairing, NPM/Docker modification or retry of the declined CI write occurred.
RC5-to-RC6 does not change bridge, wuzapi or PQ implementations. Graphical mouse
behavior, actual scrolling, mpv windows, physical microphone capture, recipient
delivery and current vulnerability advisories are unexecuted. Retained voice/GIF
semantics, media-encryption boundaries and synchronous legacy commands remain.

Use `docs/RECOVERY-3.2.0-rc6.md`. The single install command runs both full audits
before any source replacement. It is not necessary to run a redundant separate
pair first. Keep the printed rollback backup until native/live acceptance passes.

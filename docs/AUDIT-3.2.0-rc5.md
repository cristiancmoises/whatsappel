# WhatsAppel 3.2.0-rc5 — executed audit

Prepared 2026-09-10. **Release candidate. Full native/live acceptance is incomplete.**
No remote HEAD, production VPS, live account, hosted branch/tag/release or previously
declined CI write was used or changed. This is a scoped implementation review,
not independent security certification, a penetration test or a delivery guarantee.

## Provenance and boundary

The complete fixture is the checksum-verified retained 3.1 source overlaid with the
checksum-verified RC4 cumulative payload. Source and archive identities are recorded
in `SOURCE_PROVENANCE.json`. RC5 is a managed per-file delta, not a replacement
repository. It retains exact recorded earlier compatibility hashes rather than
claiming equivalence with the current Codeberg/GitHub HEAD or every older RC3 variant.

The changed Emacs source has a version-only update. The 108 retained ERT cases
remain, with the version assertion corrected; no new graphical behavior is claimed.
The bridge, wuzapi and pqenv implementation are unchanged from the RC4 fixture.
Configuration, pairing/session files, ports, NPM and independently newer PQ source
are outside the managed changes. Native candidate testing uses retained unchanged
inputs copied from the destination, not an imposed PQ snapshot.

## Findings reproduced and fixed

1. The RC4 upload reply parser accepted duplicate contradictory `wuzapi_status`
   fields and nonfinite values. A fixture containing status 500 followed by 200
   was reported accepted. RC5 rejects the ambiguity, keeps the result uncertain,
   and issues no automatic retry. Valid upstream-acceptance replies remain accepted.
   `baseline-findings.json` compares actual old/new upload functions using fake
   opener objects; separate new tests exercise real loopback HTTP child processes.
2. Worker parsing rules had diverged. Read/control/upload paths now share bounded
   strict parsing, Unicode scalar validation and POSIX deadline primitives.
   Unicode traversal uses O(depth) iterator state instead of copying every child
   reference into a traversal stack. Existing size limits and denial of redirects,
   environment proxies and insecure non-loopback HTTP remain in place.
3. Socket timeouts alone did not bound a slowly arriving upload reply. The owned
   POSIX main-thread worker now bounds the POST/reply wall time. A real slow-drip
   HTTP test with a one-second deadline checks one POST and an uncertain outcome.
   File reading/payload preparation and non-main-thread/non-POSIX cancellation
   are not covered by this wall-time mechanism.
4. The RC4 audit labelled a zero-exit unittest suite PASS despite skipped tests.
   The runner now records actual successes and distinct skipped/failed/expected
   failure outcomes. Missing/contradictory receipts cannot stand in for execution;
   zero discovered tests fail. Build convenience targets use the same semantics.
5. Installation previously relied on audit process exit codes without binding them
   to the exact candidate. It now requires distinct run identifiers, scope, ordered
   complete gates, pre/post source hashes and unchanged candidate content, then
   rechecks the bundle and original audit inputs and installs frozen candidate
   bytes. Documentation mutations and concurrent PQ edits are checked too.
6. Audit capture previously used memory proportional to command output. The new
   supervisor bounds logs to 8 MiB and runtime to 600 seconds, fails on exceedance,
   preserves nonzero exits and cleans up owned POSIX groups. Private exclusive logs,
   source-path checks and common environment-secret removal reduce accidents.
   Detached sessions, hostile same-user processes and arbitrary code in trusted
   repository tests are not sandboxed by these checks.

## Two complete full-scope executions

Both controller runs returned **1** with **5 PASS, 1 PARTIAL and 15 BLOCKED**.
Their 62 code/build hashes match before/after both executions.
Pass 1 ended 2026-09-10T11:21:02.172177+00:00; pass 2 ended 2026-09-10T11:22:43.452502+00:00.

Each Python run discovered **236 tests: 212 passed, 24 skipped,
0 failures, 0 errors**. All 24 skips require Guile and also have separate
BLOCKED native gates. They are not successes. **77 new RC5 cases passed**; a separate
targeted instrumented run also completed 77 cases successfully.

| Gate | Both complete runs |
|---|---|
| Python regression suite | PARTIAL: 212 passed / 24 Guile-dependent skips |
| Structural Lisp checks | PASS; not a native compiler or runtime |
| Read JSON benchmark | PASS; parsing/output checks, no timing threshold |
| Read envelope / streaming hash benchmark | PASS; semantic/digest equivalence |
| FFmpeg capabilities | PASS; suite also runs real synthetic media conversion |
| Source consistency | PASS |
| Emacs byte compilation, 108 ERT cases, layout benchmark | BLOCKED: Emacs missing |
| Guile unit and two real HTTP bridge suites | BLOCKED: Guile missing |
| Five fish syntax checks | BLOCKED: fish missing |
| mpv decode check | BLOCKED: mpv missing |
| Rust tests, formatting, Clippy | BLOCKED: Cargo missing |

Runtime discovery and the failed Debian package-network lookup are retained. A
missing executable does not become a success through Python or a structural scanner.
Current dependency advisory queries, graphical/media acceptance and real recipient
delivery were not executed. The unchanged Rust snapshot is not asserted to match
latest upstream dependencies. No new cryptographic guarantees are introduced.

## Regression coverage and earlier failures

New protocol tests cover duplicate/escaped keys, finite values/depth, UTF-8/scalar
Unicode, preserved multilingual values, CWD import isolation, error redaction,
validated raw forwarding, malformed/trailing JSON, real slow-drip upload and no
retries. New audit tests run actual subprocesses for discovery/skip/failure,
class skips, subtests, log flooding, closed pipes, deadlines, group cleanup,
exclusive log files, environment filtering and source-path handling.

Installer tests cover exact receipt matching, missing/stale/contradictory/duplicated
receipts, wrong scope/gates, post-test code or documentation changes, bundle mutation,
concurrent original PQ edits, immutable bytes, private backups, rollback and refusal.
Synthetic passing receipts are used ONLY inside transaction/Git-isolation fixtures.
They are explicitly labelled; they do not establish Emacs/Guile correctness and no
production option enables receipt fabrication or validation bypass.

Earlier runs are retained under `evidence/development/`: two direct tool calls were
interrupted before suite completion; one completed intermediate suite had a test
fixture error because it no longer staged required candidate bytes; the initial
grandchild test used an overly short process-start allowance. The fixture staging
and bounded process-start allowance were corrected. No failing test was removed,
and these earlier attempts are not counted as successful completed audits.

Targeted branch/line coverage is supplied in `changed-python-coverage.json`.
It instruments the parent interpreter only; worker subprocesses are exercised
by tests but not included in that coverage collection. Observed per-module
percentages are 67% audit controller, 73% shared protocol, 50% media worker,
61% read worker, 98% runner and 82% installer. This is neither whole-project nor
native coverage; percentages should not be read as security probabilities.

## Isolated performance results

Pass 2, five alternating samples, same synthetic data, identical parsed values.
This table measures **second-pass envelope construction only**, after validation,
using an in-memory counting sink. It excludes IPC copies/blocking, process startup,
networking, parsing/validation, Emacs rendering and WhatsApp delivery. Existing
input objects are allocated before traced allocation measurement.

| Fixture | JSON bytes | RC4 re-encode median ms | RC5 forwarding median ms | RC4 extra traced peak bytes | RC5 extra traced peak bytes |
|---|---:|---:|---:|---:|---:|
| unchanged | 53 | 0.004279 | 0.000884 | 1,187 | 316 |
| chats_1000 | 156,781 | 0.933844 | 0.001232 | 313,776 | 188 |
| text_4MiB | 4,194,187 | 26.289487 | 0.005337 | 9,437,786 | 180 |
| media_16MiB | 16,777,099 | 109.742808 | 0.009870 | 37,749,338 | 180 |

The practical change is avoiding re-encoding an already validated object, not
making byte transfer instantaneous. No giant whole-app speedup ratio is claimed.
A separate 32 MiB file-hash fixture measured median 39.418 ms
for read-all versus 28.889 ms for streaming, with matching digests.
Traced incremental allocations were 33,558,970 versus
1,053,645 bytes. These are Python allocation measurements,
not process RSS ceilings. Both full audit runs retain raw samples; results vary.

## Distribution and native installer gate

The final `manifest.json` and `upgrade.patch` identify the managed cumulative and
RC4-to-RC5 scopes respectively. Package tests are recorded separately in
`evidence/package-validation.json`: hashes, baseline preflights, apply/reverse,
newer-edit refusal, unchanged configuration/PQ state and rollback. Low-level file
transactions are not a substitute for native tests. All 11 package/transaction checks passed, including full application and rollback
from 3.1, RC1, RC2, the RC3 chain reconstructed from the verified RC4 reverse delta,
and RC4. A separate actual installer invocation on a disposable RC4 fixture
completed both audit passes, encountered missing native gates, and returned 1
without changing any of its 95 existing files or creating an installation backup.
No native gate was mocked in that run. Its exact result is recorded under
`evidence/native-install-*`. Subsequent changes were documentation/evidence only;
the delivered code fingerprints still match both completed audits.

Archive checksums detect inconsistencies relative to this distribution; they are
not a digital signature or independent attestation. Reports and checksums do not
protect against an attacker who can rewrite both source and evidence as the same
user. Final external archive verification is shipped alongside the archive.

Run `python3 scripts/update-package.py ~/whatsappel --audit-only --full-audit` from
the extracted package before installing. Both native audits must pass. Follow the
printed rollback instructions, retain backups, and validate graphical behavior and
real message/media delivery on explicitly approved account interactions before
routine production use. See `QUALITY-3.2.0-rc5.md` and its Portuguese counterpart.

## Primary implementation references

- Python unittest result semantics: https://docs.python.org/3/library/unittest.html
- Python subprocess buffering/timeout behavior: https://docs.python.org/3/library/subprocess.html
- POSIX signal/main-thread limitations: https://docs.python.org/3/library/signal.html

These references explain implementation choices, not evidence that this program
passed native execution or a security certification.

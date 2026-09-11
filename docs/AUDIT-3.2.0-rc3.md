# WhatsAppel 3.2.0-rc3 — executed validation

## Release decision

**Release candidate: native and live acceptance remains incomplete.** Both full
audits returned **exit 1**, each with **4 PASS and 15 BLOCKED** gates. Neither is
an overall passing audit. The release cannot be described as fully validated,
production certified, or proven faster on the user's installation.

Final run timestamps: 2026-09-10T02:59:52.595716+00:00 and 2026-09-10T03:00:22.249948+00:00 UTC.
Standard runtime used: /usr/bin/python3, Python 3.13.5. Both Python regression
runs discovered **139 tests: 115 passed, 24 skipped, 0 failures**. The 24 skipped
cases require Guile (14 existing HTTP cases and 10 RC2 read/media API cases).
Their separate native gates remain BLOCKED. All 91 supplied ERT cases, including
25 new RC3 cases, require unavailable Emacs and are **not claimed executed**.

## Provenance and scope

This iteration reconstructs RC2 from the exact retained 3.1 source plus the RC1
and RC2 managed payloads. Their SHA256SUMS manifests were verified independently:
77, 65 and 77 entries respectively, with no mismatch. Current Codeberg HEAD and
current mirror equivalence were not established this turn. Prior mirror evidence
in the historical RC1/RC2 audits must not be read as current verification.

RC3 changes the client, read worker, update/audit tooling, tests and documentation.
The bridge is byte-identical to retained RC2. The cumulative bundle also supplies
RC1/RC2 changes to known older installations. Unchanged pqenv, wuzapi, credentials,
.env and account/session data are not managed payload replacements. Staging copies
unchanged audit inputs from the target checkout; independently newer PQ files are
not overwritten by the retained fixture's PQ code.

## Two full audit passes

| Gate | Pass 1 | Pass 2 |
|---|---|---|
| lisp-structure-only | PASS | PASS |
| python-regressions | PASS | PASS |
| emacs-byte-compile | BLOCKED | BLOCKED |
| emacs-ert | BLOCKED | BLOCKED |
| emacs-layout-benchmark | BLOCKED | BLOCKED |
| ffmpeg-capabilities | PASS | PASS |
| mpv-local-decode | BLOCKED | BLOCKED |
| fish-apply-update | BLOCKED | BLOCKED |
| fish-commit-and-push | BLOCKED | BLOCKED |
| fish-deploy-ionos | BLOCKED | BLOCKED |
| fish-install-local | BLOCKED | BLOCKED |
| fish-publish | BLOCKED | BLOCKED |
| guile-unit | BLOCKED | BLOCKED |
| bridge-http | BLOCKED | BLOCKED |
| native-read-api | BLOCKED | BLOCKED |
| rust-tests | BLOCKED | BLOCKED |
| rust-format | BLOCKED | BLOCKED |
| rust-clippy | BLOCKED | BLOCKED |
| source-integrity | PASS | PASS |

Source fingerprint maps before/after both full passes are identical. The new audit
self-integrity gate rejects source mutation even when a command exits zero. It
is not a cryptographic signature or a replacement for independent review.

### Actually executed new tests

The 25 read-worker tests include 15 real HTTP/subprocess cases with multiple
adversarial subcases, plus ten validation/control tests. They run the actual
Python child against loopback servers using synthetic credentials only. Coverage:
Unicode/false/null responses; explicit read=0 and revisions; one GET; no redirect
or automatic retry; HTTP failure redaction; environment proxy non-use; duplicate,
invalid and truncated framing; streamed byte caps; compression refusal; malformed,
nonfinite, duplicate-key and deeply nested JSON; and both delayed-header and
slow-drip total deadlines. They do not exercise the real WhatsApp service.

Six additional installer/controller tests cover exact compatibility anchors,
unknown-file refusal, absent-file semantics and audit source mutation detection.
The controller fixtures deliberately mock only the invoked command so its
integrity verdict can be tested; they are not native runtime passes.

The retained Python suite also runs original-byte attachment-worker loopback
subprocess tests, no-auto-resend/error paths, real FFmpeg GIF-to-MP4 conversion,
synthetic Opus encoding, file/credential guards, archive validation, rollback and
isolated local Git publication. Its Git fixture mocks the native installer gate
only to verify isolation; no real remote commit/push is implied.

### Supplied native regressions, not executed

25 added ERT cases cover string-keyed native/fallback JSON, transport dispatch,
focused/background read flags, unknown focus, loading/empty/error distinction,
auto-poll pause semantics, one-row/zero-row/selection/order updates, viewport
prefetch and its owning window, shared media clicks and stale focus, media poll
ownership, cache eviction, stale-account sends, Write/draft behavior, invalid or
duplicate records, and an actual child-to-Emacs-loopback integration fixture.
They remain unexecuted until Emacs is available. Structural Lisp scans check only
forms and selected binding shapes; they are not Lisp readers, compilers or ERT.

## Package/installation checks

The separate package-validation.json records checks on the actual final bundle:
three retained baseline preflights/stages; matching candidate hashes; preservation
of independently modified PQ/config/session fixtures; rollback; rejection of
unrecognized managed edits; and the RC2-to-RC3 Git patch apply/reverse round trip.
The actual --apply refusal is recorded with its two mandatory changed-code audits:
no mocked gate and no installed source changes when native checks are blocked.
Final archive extraction and checksums are recorded outside the archive to avoid
self-referential hashing. These checks prove package mechanics, not native UI or
real delivery. Consult the JSON evidence for the actual individual results.

## Implemented behavior and limits

One allowlisted GET runs per Python child. Token/control uses stdin, responses
and nesting are bounded, TLS certificate checks stay enabled, redirects/proxy
inheritance are disabled, and read deadlines are enforced in the POSIX child plus
an Emacs-owned timer. The real TLS server path was not integration-tested here.
The child still has normal user privileges: this is not a decoder or OS sandbox.
Child startup overhead exists; no measured end-to-end latency gain is asserted.

Root updates replace changed rows only when stable structure permits; structural
changes retain bounded redraw. Viewport preview scheduling and queued click
coalescing reduce selected repeated work without discarding drafts. Read marking
is focused-only on v2, not a new guarantee for old bridges that ignore read=0.
No event-stream transport, complete UI rewrite, new PTT/GIF flags or PQ attachment
encryption was added. Existing administrative, legacy and other synchronous paths
can still block. Native layout, graphical scroll/click/zoom behavior, physical
microphone capture, mpv windows, WhatsApp pairing/sync/recipient delivery, IONOS
activation, all mirror pushes and current dependency advisories are NOT_RUN.

## Preparation constraints and external actions

Package retrieval attempts failed due to unavailable network/DNS; native tools
were not installed. Initial virtual-environment attempts were interrupted before
the suite completed. That environment injected unrelated spreadsheet warmup during
Python startup. Partial logs are retained separately; neither interruption is
counted as PASS. Final runs used standard system Python, ran every discovered
Python case unchanged, and retained every missing-native gate as BLOCKED.

No VPS connection, repository push, branch, tag, release or hosted workflow was
created in this iteration. The previous declined GitHub workflow path was not
retried. No real WhatsApp message, read acknowledgement or media upload was sent.

## Reproduce

```fish
python3 scripts/update-package.py "$HOME/whatsappel" --audit-only --full-audit
```

This builds an isolated candidate, runs two audits and does not install. The
installer requires both changed-code passes before writing source; no bypass is
provided. See RESPONSIVENESS-3.2.0-rc3.md for cumulative installation, diagnostics,
activation, rollback, fish entrypoints and manual acceptance requirements.

Implementation references (documentation is not evidence of local test success):
- https://docs.python.org/3/library/http.client.html
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Parsing-JSON.html
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Input-Focus.html
- https://zevlg.github.io/telega.el/

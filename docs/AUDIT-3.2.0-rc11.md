# RC11 — executed audit, not a claim of fixed live delivery

Both complete full audits returned **1**. Each reports **6 PASS, 1 PARTIAL,
20 BLOCKED**. Each Python run discovered **462** tests: **387 passed, 75 skipped,
zero failures/errors**. All 75 skips require the unavailable Guile runtime.
Missing Emacs, Guile, fish, mpv and Cargo remain native blockers, not successful
validation. The candidate supplies **193 ERT cases**, including 18 new ones,
and 21 new real-Guile HTTP cases; these native tests did not execute here.

## Scope, provenance and actual findings

The exact retained RC10 archive was verified before modification; see
SOURCE_PROVENANCE.json. The running user's provider/bridge/Emacs/phone was not
accessed. The exact live cause remains unconfirmed until the read-only report
and approved real-session checks. No messages, reconnects, callback rewrites,
privacy changes, installations or Git pushes were performed against a user account.

Source inspection found unsupported JSON jsonData envelopes, full UTF-8 decoding
of binary multipart requests before metadata extraction, omitted ordinary message
wrappers, status-only acceptance and permanent failed-image `done` entries.
The primary wuzapi helper sends file webhooks as multipart. The new native tests
exercise those contracts; because Guile is absent they are supplied, not reported
as passing reproductions of the user's failure.

The supplied init's isolated Python settings reader WAS executed on synthetic
configurations. Its old PUBLIC_URL-only fallback returned the callback as the
client URL; the separate v2 correction rejects that ambiguity. The exact raw
user init is not embedded in this public project package. Local HOST/PORT and
explicit client origins remain supported. No claim is made that the user's
actual secret configuration uses the problematic fallback.

The new send worker and acknowledgement parser were exercised using real child
processes and loopback HTTP. **32 new Python tests passed**, also in a separate
targeted run: UTF-8 bodies, one POST, real accepted IDs, missing/conflicting IDs,
nested failure, duplicate JSON, denied redirects, slow-drip deadlines, oversized
responses, invalid controls, explicit repair confirmation, redaction and read-only
diagnostic output. Fixture network traffic is not real WhatsApp delivery.

## Changed behavior and limits

An ID establishes provider acceptance only. Matching authenticated receipts label
existing own messages delivered/read; unknown receipts create no records. An
uncertain send is not resent automatically. Explicit callback repair preserves
verified event subscriptions and refuses an unrelated callback without a separate
confirmation. Registration does not establish reachability and upstream supplies
no atomic compare-and-swap. A stalled Guile request can retain its separate slot;
legacy provider calls in the main server remain synchronous.

Native images remain and a bounded GIF viewer is supplied. GIF structure limits
are not a decoder sandbox; native display/GIF tests remain blocked. **Pale's API
could not be retrieved and no real Pale binding is implemented.** Its requested
default preference launches nothing with an explicit unavailable error. mpv is
an explicit setting, not silent fallback. This means default video playback is
not functional until a verified binding exists or mpv is chosen. Native images
and GIFs are not implemented using Pale. No native/GUI speedup was measured.

## Identical-source audit receipts

Pass 1: `176726a8b5464f9a82b875ce8e77eace`, completed `2026-09-10T18:05:20.876939+00:00`.
Pass 2: `d0234451684146908cded8757f14163d`, completed `2026-09-10T18:07:07.697096+00:00`.
All **87 code/build fingerprints** agree before/after both runs and with the
candidate. Prose and package evidence were assembled afterward. See the raw
reports/logs under evidence/final-pass-1 and final-pass-2.

The baseline full audit was also executed and retained: 409 discovered, 355 passed,
54 skipped, zero failures/errors; incomplete native coverage. The development
suite exposed two old tests asserting the now-rejected callback→client alias.
Those tests were updated to assert the new safe origin semantics, not removed;
other guards and the prior repaired native assertions remain. A new ERT fixture
had a delimiter error during writing; structural checking caught it before final
audits. Structural Lisp checking is not a compiler/interpreter or ERT execution.

## Delivery and safety

The cumulative installer still requires two exact-candidate native audits. No
skip/bypass switch, forced patching, profile/system mutation, or session reset was
added. Complete-source files are for reproduction/new installation; normal update
uses managed hashes, preserves configuration/sessions, and audits independently
newer PQ source from the actual target without replacing it.

Package application, rollback, integrity and refusal checks are recorded separately
in evidence/package-validation.json; they are not successful native installation.
SHA-256 manifests prove consistency with this bundle, not a maintainer signature,
independent security certification or protection against a same-user attacker
rewriting source and evidence together.

Primary implementation references inspected: wuzapi helpers.go (direct/form/file
webhooks), handlers.go (/session/status, /webhook, send IDs), and GNU Emacs 30
image.el (image-animate/image-animate-timer). Their contracts are not evidence of
this installed provider version or this candidate's native execution. Current
provider dependency advisories, photographs, microphone, GUI playback, Pale,
actual send/receive receipts and VPS activation remain unverified.

## Final distribution and actual refusal

All 12 package/transaction checks passed, including direct RC10 preflight, exact
application/rollback, unrelated configuration/session/PQ preservation, unknown-edit
refusal, review patch reversal, and equality to both audited code fingerprints.
The first packaging fixture incorrectly precreated an exclusive backup directory;
it was corrected and rerun without changing the installer guard. Complete-source
assembly includes the retained Go contribution files; generated caches are excluded.

A separate invocation of the actual guarded Guix updater on a disposable RC10
fixture ran both full audits without mocking the native gate. It returned 1, left
all 150 pre-existing files unchanged, and created zero installation backups.
`evidence/native-install-refusal.json` and its log record this refusal, not a native
installation success.

The separate optional init-v2 helper passed 11 Python/file-safety and exact-content
checks. Its extracted Python compiles. Native fish syntax, Emacs syntax, and full
init startup remain blocked/not run here; the helper requires the user's Emacs
syntax check before replacement. This does not audit unrelated user configuration.
The full personal init is delivered separately and is not included in this source
package.

# RC15 — executed audit and release limits

Prepared 2026-09-10. **Release candidate; native and live acceptance incomplete.**
Both final full audits returned 1: 6 PASS, 1 PARTIAL, 21 BLOCKED. A blocked native
gate remains a blocker. No user service, session, callback, message or remote
repository was changed in preparation.

## Provenance and scope

Baseline: complete RC14 archive SHA-256
`5c322f2a125ff0f50982dcf46fd4893c9c3ab1d4a7620a60516d904b17e92682`. Its 464 internal checksums
were verified before modification. RC14's original responsiveness test file is
byte-identical, including the reported late-account assertion. The RC14 warning
remains. The old supplied report naming an RC11-era failed transport fixture and
its passed native gates do not establish this candidate's correctness. No latest
remote HEAD or current operator source/runtime was accessed.

Source inspection identified an unguarded call to history refresh after successful
send acceptance. RC15 catches that local follow-up failure without changing the
accepted note/provider ID, newer draft, late-account rejection, duplicate callback
protection or no-resend semantics. Four new native ERT cases are supplied, not
claimed executed. Accepted still is not delivered. This is not a newly reproduced
live phone-delivery defect or a measured UI responsiveness result.

The added finish-update.py/update-and-activate.fish wraps the unchanged source
installer. Activation is optional and limited to explicitly authorized, matched
local user Shepherd service metadata, source, account/port, process lifetime and
owned listening socket. Update failures cannot reach restart. Post-install payload
hashes, account/service stability and a new process are checked. HTTP transport is
probed independently of health advertisement. Contradictory versions do not pass.
Runtime verification remains separate from callback registration and phone delivery.
No additional Guile application behavior changes; bridge edits are version labels.

## Tests actually executed

- Baseline full audit: 466 discovered, 389 passed, 77 skipped; native gates unavailable.
- Final pass 1: run `3dba84b6f57c4408b6ac0604c6da7340`, completed 2026-09-10T21:45:02.225965+00:00.
- Final pass 2: run `4ef4fc8d27ba41b3a298554b598e15b0`, completed 2026-09-10T21:45:53.805148+00:00.
- Each final Python suite: **521 discovered/run, 444 passed, 77 skipped, zero failures/errors**.
- All 77 skips require Guile; suite is PARTIAL, not successful native integration.
- **55 new Python cases pass**, also in an isolated targeted run.
- **220 ERT cases supplied**, four new; no Emacs runtime available to execute them.
- **91 code/build SHA-256 fingerprints** match before/after both final runs and source.
- Existing structural Lisp checks, JSON/envelope/thumbnail benchmarks, FFmpeg capability
  and source-integrity gates passed. They are not Emacs or Guile execution.
- Emacs compilation/ERT/two layout benchmarks, eight fish syntax checks, Guile unit/
  four HTTP suites, mpv decoding and Rust test/fmt/clippy gates are BLOCKED.

Actual new Python tests execute bounded child commands, delayed/flooding processes,
loopback HTTP including redirect rejection and no POST, a real CLI check subprocess,
private report writes, no-overwrite behavior, and the current test process's real
Linux listener inode. Synthetic /proc Guile metadata tests cover wrong UID/source/
account/port/socket, duplicate settings and symlink refusal. **Updater/herd success
in sequencing fixtures is mocked solely to test ordering; it is not an audit receipt,
real service restart, live bridge or successful application installation.**

No raw user tokens/contacts or provider data are copied to reports. Local service
output is captured within 64 KiB and 15 seconds and not echoed. Source/proc reads
are bounded. Same-UID hostile mutation, changes after a check, detached processes,
and arbitrary code in trusted existing test files remain outside this protection.

## Development evidence

The first new test run had 15 fixture errors: mock UID 1000 conflicted with the
root-owned temporary .env. The synthetic file ownership was aligned with the mocked
UID (only in test temporary files). Seven inherited duplicate file tests were
removed from the sequencing subclass; they still run unchanged in their own class.
No failed behavioral assertion was deleted or weakened. The corrected targeted
runs and a complete development audit passed executable cases; final additional CLI
cases and service-lifetime checks were then added and the final full pair rerun.
Original failing and development logs remain included.

Native package lookup was attempted through apt and returned DNS failures, without
obtaining a runtime. An official Debian download through the available tool also
failed. Missing tools are not approximated using source shape checks or old uploaded
native results. GNU Guix itself, real profiles, GUI, microphone, Pale and current
dependency advisory scanning were not executed. No new performance ratio is claimed.

## Distribution and operator gate

Complete source is for reproduction/new installations; the cumulative managed update
preserves explicit earlier anchors, .env, sessions, init and independently newer PQ
inputs. Unknown edits are refused. Package transaction/rollback tests are recorded
separately, and do not replace native audits. Both full native audits on the actual
Guix workstation are still mandatory. A separate actual failed-installer exercise
is labelled separately from mocked sequencing tests.

After success, fully restart Emacs/daemon and inspect the loaded version. A running
Emacs process is not updated by copying source. Automatic activation only supports
the verified direct local user Shepherd/Guile setup over numeric loopback HTTP;
other configurations are refused, not inferred. Existing source-only updater and
publication scripts remain. A restart/health failure after installation leaves
new source and backup in place; there is no automatic rollback of live state.

Pale integration remains unfinished, and no video default or global theme changes
are made. Photos/status/privacy and real delivery require live acceptance. No
previous uncertain send is automatically retried. Checksums prove distribution
consistency, not a maintainer signature or independent security certification.

References: GNU Emacs Lisp Manual, Sentinels (callback exceptions and process-error
pauses) and Asynchronous Processes; GNU Shepherd Manual, Invoking herd. These explain
implementation choices, not this application's native correctness.

## Final packaging and actual refusal

All 14 packaging checks passed: internal manifests; complete-source/payload equality;
matching final audit fingerprints; unchanged original late-account regression;
RC10/RC11/RC13/RC14 low-level update plus exact rollback; newer-edit rollback refusal;
unknown-edit, symlink and corrupt-payload refusal; exact review-patch application and
reversal; and an actual check-only CLI. These transactions do not bypass a production
native gate: they exercise low-level file operations and are labelled accordingly.

A separate actual invocation of finish-update.py (default update, no restart option)
ran as non-root UID 1000 against a disposable RC14 installation. The unmodified
production updater ran two full audits, returned failure for partial/blocked native
coverage, and left all **174 pre-existing files byte-identical**. Configuration,
synthetic session data, bytecode and independently newer PQ source were preserved.
There were **zero installation backups and no restart attempt**. No native gate was
mocked. See evidence/native-install-refusal.json and both native-install-pass reports.

An initial disposable fixture used root-owned private bundle evidence while invoking
it as another user; verification correctly failed before the audit. The copied test
bundle's ownership was corrected, as would occur when the operator extracts their
own archive, and the complete real refusal run above followed. Another packaging
fixture initially included its synthetic .git metadata in source equivalence; the
snapshot helper excluded .git and all checks were rerun. Neither correction changes
application code or relaxes installation/native assertions. Earlier evidence is kept.

Documentation/evidence is finalized after code audits. The external archive verifier
checks the final extracted source and all managed payloads against their manifests
and the same 91 code fingerprints. No runtime success is inferred from these hashes.

# WhatsAppel 3.2.0-rc10 — profile validation repair and actual audit

Prepared 2026-09-10. **Candidate. Native and live acceptance remain incomplete.**
No remote write, deployment, account interaction, automatic service restart, or
provider subscription change was performed. Runtime acquisition was attempted in
this preparation container, not on the user's machine, and failed DNS resolution.

## Operator diagnosis (RC9, not RC10 execution)

Both uploaded archives have SHA-256
`6a009693c25d2b8374cab20371ebb3f47ec0007ea786f59b06613a66af9511a3`.
Both reports match all **79 code/build hashes** in the retained complete RC9 source.
The RC9 distribution archive SHA-256 is
`7dda0d9fd35485b7a82d1351b393093ece43153c63bfee75b60c9137763ac36b`.
All 413 prior checksums were verified before editing.

Each operator run: **24 PASS, 2 FAIL** gates. The combined Python suite had
**386 passes and 1 failure out of 387**, zero skips. The dedicated profile suite
had **17 passes and the same 1 failure out of 18**. Both point to
`test_profiles_http.ProfileHTTPTests.test_invalid_event_group_and_duplicate_keys`:
the group-presence assertion expected HTTP 400 and received HTTP 200.

The handler returned ignored for an uncached identity before reaching field
validation. Its authenticated HTTP wrapper translates ignored to 200. Validation
therefore depended on prior cache state. The ignored event did not create a record;
these logs do not establish displayed group-wide online state, arbitrary account
access, or a credential leak. `evidence/diagnosis.json` preserves only hashes,
counts and synthetic test identities; private operator archives are not included.

## Implemented correction

`profile-event-change` validates/normalizes presence, activity and picture fields
without touching shared state. `profile-event!` rejects an invalid normalized result
or timestamp **before** cache/stale filtering. Existing records are mutated under
the existing profile mutex only after validation. Unknown valid contacts remain
ignored without storage, outbound requests or changed message history.

Group-wide presence/activity is rejected; group photographs remain permitted.
Explicit source fields, last-seen privacy fallback, activity expiry, separate
profile/history revisions, authenticated webhook routes and bounded job pools are
retained. No new direct I/O, decryption, rendering work or image decoding is added
to contact selection. No latency improvement was measured or asserted.

The exact original failing test method remains unchanged. **12 new native HTTP
regression methods** cover cached/uncached flat/native group events, invalid direct
states, invalid activity/media/chat fields, invalid picture-removal types, bad
timestamps, valid unknown events, valid group pictures, prior-state preservation,
stale valid/invalid events, duplicate keys and no changed message/upstream traffic.

The controller now extracts bounded dotted Python failure IDs from fixed sibling
receipts, never arbitrary report paths, traceback values or subtest arguments.
Malformed/duplicate/oversized/linked receipts yield no guessed names. This output
never changes gate status. **10 new Python diagnostic tests pass**, using actual
receipt files and the existing read-only summary function. The updated summarizer
was run against both uploaded RC9 reports and printed the same single failed ID
for both failing gates, preserving failure status.

## Two full RC10 audit executions

| Gate | Both final runs |
|---|---|
| Python suite | PARTIAL: 409 discovered, 355 passed, 54 skipped, 0 failures/errors |
| Structural Lisp check | PASS; not a Guile/Emacs reader, compiler or evaluator |
| Retained JSON/envelope/hash benchmarks | PASS; no new speedup claim |
| Retained FFmpeg thumbnail benchmark | PASS; synthetic data, no real profile photo |
| FFmpeg capabilities | PASS |
| Source integrity | PASS: 80 identical code/build hashes |
| Emacs compilation, ERT, layout/profile benchmarks | BLOCKED: Emacs absent |
| Seven fish syntax checks | BLOCKED: fish absent |
| Guile unit and three native bridge HTTP gates | BLOCKED: Guile absent |
| mpv decoding | BLOCKED: mpv absent |
| Rust tests, format, Clippy | BLOCKED: Cargo absent |

Each controller returned **1**: **6 PASS, 1 PARTIAL, 19 BLOCKED**. The 54 skips
are the 24 earlier bridge/read cases plus 30 profile cases (18 retained + 12 new).
The ten new executed cases validate diagnostics, not the Scheme runtime. There are
**175 retained ERT tests**, with the version assertion advanced; none ran here.
No scheme-in-Python emulator or fake executable is substituted for native tests.

Pass 1 ID `c1941a4068d047cf829c42b4f9347375`, completed `2026-09-10T15:54:40.091354+00:00`.
Pass 2 ID `b567d6cf00ec46158b5b3839842f0b5e`, completed `2026-09-10T15:56:41.856542+00:00`.
All code fingerprints match before/after both runs and the delivered source.
Documentation/evidence is finalized afterward. Preparation runtime: Python
3.13.5, Linux-6.18.35-x86_64-with-glibc2.41. No Emacs, Guile, fish, mpv,
Cargo or Guix executable was available. The operator's working Guix toolchain is
not remotely accessible via a log archive.

`evidence/diagnostics-tests.json` records the separate ten-test successful run.
The complete Python suites also execute retained real loopback HTTP, workers,
original-byte/redirect/deadline/no-resend tests, media conversion and isolated Git
transaction tests. Their successes are not native UI or live delivery evidence.

## Distribution and release decision

The package is a cumulative managed update with recorded prior SHA-256 anchors,
not a replacement of the active repository. Current remote HEAD and unrecorded
historical variants are not asserted compatible. The full source snapshot retains
optional prior PQ code; normal update never overwrites independently newer PQ code,
configuration or sessions. That target's actual PQ input is used for validation.

Use the single fish update command in the README. Its exact-candidate two-pass
native gate is unchanged; required FAIL/PARTIAL/BLOCKED outcomes prevent writes.
The package has no new bypass, force flag, fabricated successful audit or disabled
original regression. Packaging/rollback tests validate file mechanics only.
See `evidence/package-validation.json` and any separately labelled real installer
refusal report for executed results. Checksums are consistency checks, not digital
signatures or protection against a hostile same-user process rewriting evidence.

After successful installation, restart Emacs and the actual Guile bridge process.
RC10 changes the bridge's loaded profile module. No process/service name is guessed.
Live photos/presence forwarding, mouse/scroll behavior, microphone/mpv, recipient
delivery and current dependency advisories remain unexecuted. Pale is not added
by this repair; media-player behavior is unchanged. This is a scoped development
review, not a penetration-test certificate or guarantee of complete correctness.

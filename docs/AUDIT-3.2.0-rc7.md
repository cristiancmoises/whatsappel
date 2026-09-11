# WhatsAppel 3.2.0-rc7 — executed audit and distribution boundary

Prepared 2026-09-10. **Release candidate: native and live acceptance remains incomplete.**
Both full-scope controllers returned **1**, not success. Each contains 5 PASS, 1 PARTIAL,
and 17 BLOCKED gates. Missing tools cannot be substituted by Python tests or structural
Lisp scanning. No hosted code mutation, VPS action or real WhatsApp message occurred.

## Source provenance

The retained full 3.1 source was overlaid with the SHA-256-verified RC6 cumulative payload.
The RC6 archive hash and exact managed/changed paths are in `SOURCE_PROVENANCE.json`.
Current Codeberg/GitHub HEAD was not fetched or asserted equivalent. The earlier operator
RC5 native successes and RC6 repair diagnosis are not RC7 native results. RC7 preserves
the history-button/SRFI-64 repairs; it does not weaken them or turn failures into skips.

The full archive now includes `source/`, not only a delta. This is a complete retained
snapshot plus RC7 changes, including optional retained PQ source. **Normal update never
copies that complete snapshot over the user's existing tree.** It uses only explicit
managed paths and copies independently newer PQ inputs from the actual target for tests.
No .env, session, private key, pairing or provider credential is distributed as user data.

## Findings and changes

1. **Mixed-source account configuration.** RC6 Python launch could combine an environment
   token with an unrelated .env URL; its Lisp entry point could update an external URL
   while keeping an init token. The real old/new Python `main` functions were executed
   with synthetic settings and mocked `execve`: RC6 borrowed the unrelated file URL,
   RC7 did not. No real Emacs or HTTP request was made in that fixture. RC7 selects external
   account settings as a pair, token-only explicitly selects loopback, and URL-only cannot
   borrow another source's token. Six new native ERT cases are supplied for Lisp behavior.
2. **Guix update usability.** One fish entry point uses the already-working current native
   environment and invokes both full audits before updating existing source and desktop
   registration. No guix pull, profile/system mutation, dependency installer, guessed
   service restart, automatic account linking or Git push occurs. `--check` and `--audit-only`
   are explicit. Do not claim this is a Guix channel package or a measured startup speedup.
3. **Fresh source installation.** An explicit flag validates the complete snapshot, stages
   privately, uses the normal full two-pass gate, rechecks exact source, and publishes with
   Linux `renameat2(RENAME_NOREPLACE)`. Real tests exercised the no-replace syscall, including
   an already existing empty directory and spaces in paths. Transaction tests intentionally
   mock the native gate/desktop call to test sequencing only; they do not prove native
   application correctness. Failed audit cleanup leaves reports outside the stage.
4. **Publication.** Committed baseline blobs are checked as raw bytes (including CRLF/UTF-8)
   before worktree creation. Nested unrelated repository paths are rejected. Publication
   candidates now receive **full** audits rather than changed-only audits. `--check` makes
   no worktree/commit/network request. A separate fish command retries an already clean,
   committed snapshot without restaging. The commit message describes RC7 instead of RC5.
5. **Documentation.** Replaced contradictory layered README release headers with current
   English/Portuguese guides, archived historical text, and documented update vs fresh
   source, account precedence, rollback, four exact remotes, and scope limits.

## Full audits (identical code)

| Gate | Both runs |
|---|---|
| Python suite | PARTIAL: 329 discovered, 305 passed, 24 skipped, zero failures/errors |
| Structural Lisp checks | PASS; not an Emacs/Guile reader/compiler/runtime |
| Retained JSON benchmark | PASS; retained algorithm, not an RC7 performance comparison |
| Retained envelope/hash benchmark | PASS; not an RC7 end-to-end speedup |
| FFmpeg capability check | PASS; retained tests also exercise real synthetic media fixtures |
| Source integrity | PASS; 68 code/build hashes unchanged |
| Emacs compile, ERT, layout benchmark | BLOCKED: Emacs unavailable |
| Seven fish entry-point syntax checks | BLOCKED: fish unavailable |
| Guile unit and two bridge HTTP suites | BLOCKED: Guile unavailable |
| mpv decoding | BLOCKED: mpv unavailable |
| Rust tests, format, Clippy | BLOCKED: Cargo unavailable |

The 24 Python skips are the Guile-dependent HTTP cases, also independently blocked above.
**45 new RC7 Python tests pass** in both full suites and a separate targeted run. Existing
loopback/worker/FFmpeg/Git-isolation tests remain. There are **124 supplied ERT cases**,
including 6 added here; none were executed in this environment. GNU Guix itself is absent;
its package/channel resolution was not tested or changed. A Debian package endpoint lookup
failed DNS resolution. No attempt was made to bypass runtime or CI authorization limits.

Run 1: `eedec45997bb462a86ce0790b05c0fb7`, completed `2026-09-10T13:06:18.248686+00:00`.
Run 2: `9d088faaea374ea8a78f0253d4df0541`, completed `2026-09-10T13:07:34.653240+00:00`.
The report source maps match before and after both runs. Developer first audit invocation
was interrupted by a short container-command timeout; its partial log is retained, not
reported successful. A subsequent development run and both final complete runs are retained.
The first 41-case and final 45-case targeted runs passed; no tests were deleted to pass.

## Package and actual refusal evidence

`evidence/package-validation.json` records 11 successful packaging/transaction checks:
application plus exact rollback from 3.1/RC1/RC2/RC4/RC5/RC6, unknown-edit refusal, RC6 patch
roundtrip, complete-source/payload equality, fresh check-only with no target, and complete
source tamper refusal. Those low-level transactions do not execute native audit gates.
RC3 compatibility anchors are retained from the verified RC6 chain; unrecorded RC3 variants
remain unsupported rather than guessed compatible.

A separate **actual** invocation of `guix-workflow.py` in default update mode runs the normal
full two-pass installer gate on a disposable RC6 tree with synthetic private settings,
session data and independently modified PQ source. Its nonzero result, per-pass outcomes,
exact unchanged-file count and absence of installation backups are recorded in
`evidence/native-install-refusal.json`. No native gate is mocked in that invocation. The completed invocation returned 1, left all 113 existing files unchanged, and created zero installation backups.

Prose/evidence is finalized after code testing; final extracted source fingerprints must
match both reports. The external archive-verification report checks internal checksums,
complete source, managed payloads, and patch distribution. SHA-256 files are consistency
checks, not a maintainer signature or independent attestation. An adversary with the same
user's write access to both code and evidence is outside this assurance.

## Remaining acceptance

No measured RC7 chat-loading/startup speedup, graphical screenshot, live pairing, physical
microphone test, mpv window, message delivery, dependency advisory review, VPS deployment,
remote push/tag/release or service restart is asserted. RC6-to-RC7 does not change bridge,
wuzapi or PQ implementation. Existing media/PTT/GIF/encryption/synchronous-path limits
remain. Run the full native gate on the actual installation and validate real interactions
before routine use. Keep the printed rollback backup until acceptance succeeds.

See `README.md`, `README.pt-BR.md` and `docs/GUIX-3.2.0-rc7.md`. This is a scoped developer
review with reproducible evidence, not an independent security certification.

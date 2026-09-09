# WhatsAppel 3.1 audit — 2026-09-09

## Scope and baseline

Source: https://codeberg.org/berkeley/whatsappel, `main`, commit
`322d64d83a5e1b1f065f3b9113a37ae90570e4d5` (version 3.0.3). The work is a source
upgrade candidate, not a published release or security certification. The audit
covered Emacs/Org code, Guile bridge, optional Rust PQ envelope/ratchet, setup and
service examples, optional Go retry contribution, dependency lockfile, and the
new patch/publication scripts. It combined source review with regression tests,
real local HTTP processes and a graphical fixture smoke check.

No user tokens, linked WhatsApp account, private conversation, remote push,
server deployment or recipient messaging were used. Optional Go contribution
and Guix Home examples received source review; they were not built/deployed
against your actual wuzapi/Guix version.

## Findings and disposition

| Finding | Severity assessment | Change / evidence |
|---|---|---|
| Received text could expand executable Org capture placeholders or escape its quote block | High when the user captures crafted content | Correct placeholder escaping and literal example blocks; real org-capture expansion regression tests |
| Org send export could evaluate Babel/macros or include local files | High in an untrusted Org document | Export disables those expansion paths; tests verify no evaluation or file inclusion |
| PQ ratchet concurrent writers and in-place state truncation | High for users of the optional ratchet CLI | OS advisory locks, atomic private state replacement, ordering and replay/CLI tests |
| Secret output symlinks, permissive replacement and replay read failures | High for optional PQ under affected local-file conditions | Refuse unsafe outputs, private atomic files, create-new identities/prekeys, fail-closed replay reads |
| Envelope/ratchet trailing bytes and weak CLI argument handling | Medium | Strict parsing, freshness checks and tampering tests; protocol versions preserved |
| Bridge startup exposed webhook token; LID database path used a shell | High for exposed logs/untrusted configuration | Redacted startup and direct process argv; regression checks |
| Ambient proxy could receive local wuzapi token because Guile ignores no_proxy | High with an affected inherited proxy configuration | Explicit loopback upstream proxy bypass, tested with a hostile proxy setting |
| Duplicate/own webhook events increased unread; sync could erase live history | Medium | ID deduplication, own-message handling, merge-based import and ordered timestamps |
| Malformed objects, poison timestamps, unchecked MIME/base64 and broad URL relay | Medium | Validated input/config, strict media routing and metadata, upstream error handling |
| Unbounded caches/raw events; repeated synchronous polling and rendering | Medium availability/usability | Cache/chat caps, raw-event retention removed, async visible-buffer refresh and limited media prefetch |
| JSON false and unsafe contact-key paths in client | Medium | Explicit boolean semantics, safe cache keys and contact filenames |
| Setup permissions window, shell-style systemd env and missing Guix wuzapi env loading | Medium/low depending on deployment | Restrictive umask, no-clobber environment creation, corrected runtime loading and explicit loopback |
| Missing audit runner and deployment history/token hazards | Medium operational | Working audit target; isolated patch application, scoped hidden credentials, FF-only verified publication |

These severity assessments describe potential impact in the affected paths;
they are not assigned CVEs or independent exploit certifications.

## Reproduced validation

| Check | Result |
|---|---|
| Emacs 29.3 byte compilation | Both client and Org files compile cleanly |
| ERT client and Org | 28 passed (23 client + 5 Org) |
| Guile 3.0.9 / guile-json 4.7.3 | 78 Scheme checks passed |
| Real Guile HTTP + local mock wuzapi | 14 integration tests passed |
| Publication/application Python suite | 25 passed; 1 Unix-socket helper test skipped because this runtime prohibits AF_UNIX |
| Rust 1.93.0 / Cargo 1.93.0 | 39 tests passed, including real CLI envelope and ratchet round trips |
| Rust formatting and all-target Clippy with warnings denied | Passed |
| fish 3.7.0 / Bash syntax | Both fish wrappers and shell scripts passed |
| systemd unit verification | `systemd-analyze verify whatsappel.service` passed |
| Graphical Emacs smoke | Dashboard and conversation rendered; draft retained across redraw; screenshots inspected |
| Patch packaging | Baseline application and resulting file-tree verification recorded with delivery evidence |

**184 automated checks passed, with one additional test skipped.** Counts do not
include compiler/lint gates or the graphical smoke. The publisher's credential
scope logic is tested separately, but a real Unix-socket credential exchange and
real forge authentication/push require a normal local Linux environment.

The initial Xvfb Unix-display attempt failed due to the same socket restriction.
A local authenticated TCP X11 display succeeded. Screenshots use fictional
contacts and no network calls. This verifies the rendered dashboard/composer,
not real inbound image decoders, animation, or real mouse interaction on your DE.

Run `WHATSAPPEL_AUDIT_ADVISORIES=1 make audit` in Bash, or
`env WHATSAPPEL_AUDIT_ADVISORIES=1 make audit` in fish. Detailed stdout/stderr
and the per-gate summary are included in the delivery's `evidence/` directory.
The audit command exits nonzero for failed checks or missing required tools;
its detailed unittest log records environmental skips.

## Dependencies

The baseline lockfile triggered three RustSec vulnerability advisories:
[RUSTSEC-2026-0212](https://rustsec.org/advisories/RUSTSEC-2026-0212.html),
[RUSTSEC-2026-0207](https://rustsec.org/advisories/RUSTSEC-2026-0207.html) and
[RUSTSEC-2026-0208](https://rustsec.org/advisories/RUSTSEC-2026-0208.html).
The SHA3 advisories explicitly distinguish unaffected ML-KEM/ML-DSA uses; the
secrets finding concerns AArch64. The lockfile was still updated through
supported libcrux releases instead of assuming all target combinations safe.

Updated ML-KEM and ML-DSA crates are 0.0.10, bringing patched SHA3/secrets
versions. The final scan used RustSec database commit
`d502590ca247f3e53b56bf6c2ae40b61926800e5` and checked 150 dependencies:
**zero reported vulnerabilities**. One unmaintained transitive build dependency,
`proc-macro-error2 2.0.1` ([RUSTSEC-2026-0173](https://rustsec.org/advisories/RUSTSEC-2026-0173.html)), remains documented; no patched replacement was
available in its advisory. A clean vulnerability result is not proof that this
custom cryptographic protocol is secure. See `pqenv/README.md` and [the PQ audit](../pqenv/AUDIT-2026-09-09.md)
for platform assumptions, state rollback/crash limitations and the threat model.

## Remaining limits and deployment checks

- Guile buffers the incoming body before the application checks its size. The
  configured body cap does not prevent pre-handler allocation or slow clients.
  Upstream requests have no total timeout and can block the single HTTP handler.
  Keep the service on loopback; it is not ready as an unrestricted public API.
- Count caps are not a strict process-memory bound. Explicit send, media open/save,
  sync and PQ subprocess work still block Emacs until completion/client deadline.
- Native format/codec compatibility, original-document delivery through WhatsApp,
  QR login, reconnect, receipts and expired-media retry need your live smoke test.
- Checked official wuzapi `handlers.go` at commit
  `919c72c9750b2a1eedf0fcf9c9592f05fe46f61c` supports `MimeType`, but `SendVideo`
  has no `GifPlayback` field. The unsupported field was removed; `/send/gif`
  remains an MP4 video alias. Raw GIFs are original documents. There is no promise
  of automatic GIF transcoding or looping. [Upstream source](https://github.com/asternic/wuzapi/blob/919c72c9750b2a1eedf0fcf9c9592f05fe46f61c/handlers.go).
- Optional PQ is a custom, opt-in protocol, not post-quantum WhatsApp. The in-chat
  single-shot envelope has no forward secrecy; durable receive-side replay
  acceptance across restarts is not integrated with the UI. Ratchet CLI file
  locking does not defeat malicious state backup/rollback or endpoint compromise.
- Go retry changes bound the request body and propagate request cancellation;
  the contribution still requires integration/build testing with your wuzapi.
- Your four tokens, repository existence/visibility, forge policy and fast-forward
  state will be checked when you run the provided scripts. No deployment happened
  during this audit.

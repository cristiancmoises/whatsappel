# WhatsAppel 3.2.0-rc9 — executed profile-workspace audit

Prepared 2026-09-10. **Release candidate; native, graphical and live-account acceptance
remain incomplete.** The two completed final audits each returned **1**: 6 PASS,
1 PARTIAL, 19 BLOCKED. Source is the retained RC8 distribution, not a live checkout
or a remotely observed running Emacs instance. Nothing was pushed or deployed.

## Provenance

The supplied RC8 archive SHA-256 is
`2d0e34f6eb278b2dd8dd2a187af5397282152fa0bc0cda1e765706eed571b4ef`.
All 338 original internal checksums were verified before modification. The complete
128-file RC8 source is the baseline; existing optional PQ source is retained.
Normal update uses explicit managed paths, not the whole source snapshot, so
independently newer PQ source from the actual target remains an audit input.
Current Codeberg/GitHub HEAD, the operator's installed provider version and their
loaded native code were not inspected or asserted identical. Historical compatibility
anchors remain explicit; unfamiliar edits and unrecorded variants are refused.

## Implemented scope

New native buffer-local palette, avatar gutters, header/status, contact-info panel,
settings, Emoji insertion and diagnostics retain the existing workspace/sidebar,
compact/comfortable modes and RC8 compose-first selection, drafts, bounds and
explicit asynchronous Decrypt. The application is still Emacs, not a web frontend.
No global theme change, outgoing typing announcement, automatic self-online call,
new PTT/GIF flags, pin/mute implementation, stories or cryptography is claimed.

`whatsappel-profiles.scm` extends the existing authenticated bridge with separate
metadata and job state. `scripts/profile-worker.py` performs bounded asynchronous
queries and controlled photo retrieval/conversion. `whatsapp-profiles.el` supplies
the UI, memory caches, visible-work queue and explicit account-scoped consent.

The new bridge APIs are GET `/profile/capabilities`, GET `/profiles?jids=...`,
POST `/profile/request`, and GET `/profile/job?id=...`. Upstream operations are
POST `/user/avatar`, POST `/user/info`, and POST `/user/presence/subscribe`, as
registered by inspected upstream routes. The installed provider contract remains
an acceptance prerequisite; HTTP 404/405/501 becomes unavailable, not fake success.
The bridge scopes upstream profile JSON reads to 32KiB before parsing; default
limits on unchanged transport operations are retained.

Presence is based only on observed typed events. Availability expires after 60s,
activity after 8s; hidden/zero/future last-seen timestamps do not become estimates.
Groups have no group-wide online state; remote Idle/Away is unsupported. Picture
changes/removals invalidate cached/in-flight photos through identity/revision/epoch
checks. No-timestamp events use receipt order, not a claim of remote ordering.

**Presence event forwarding is not automatically provisioned.** Existing Message
subscriptions are unchanged. The operator must preserve existing provider settings
and forward supported Presence/ChatPresence/Picture events before the corresponding
features have data. The client does not reset/re-pair/reconnect an account to do so.
Some providers require self-availability for presence delivery; RC9 neither changes
that prior behavior nor silently announces availability. Disabling consent stops
future subscriptions; no upstream unsubscribe endpoint is invented.

## Security and performance boundaries

Photo URLs are accepted only at exact HTTPS `pps.whatsapp.net:443`; redirects,
credentials, alternate ports, invalid escapes and unsafe resolved addresses are
refused. DNS addresses are checked once; the actual socket connects to a vetted
address and TLS verifies the original hostname. No bridge/provider token or cookie
is forwarded to the CDN. Other legitimate CDNs/formats currently fall back rather
than expanding an unverified allowlist.

JPEG/PNG input is bounded to 2MiB, 4096 on either edge and 4 million pixels. An owned
FFmpeg process produces a 96/256px PNG with CPU/address-space/output/time limits.
Tests exercise actual FFmpeg, but TLS/DNS pinning fixtures mock socket/resolver
boundaries; **no real CDN request or photo from a real account was tested**.
Prepared native decoding is deferred and small, not a complete codec sandbox.

Client work: 2 active jobs, 16 queued, 12 visible IDs per metadata snapshot; normal
visible reads/sends take priority. Metadata is limited to 128 entries; prepared
photos to 32 entries/4MiB/1 million pixels, memory-only, 120s TTL. These are selected
cache budgets, not whole-Emacs RSS ceilings or secure memory erasure. The bridge
also bounds its metadata and two-slot job pool; completed jobs expire after 30s.
Normal history revisions/unread state do not change with profile events.

The Python worker has a 20s normal deadline and Emacs adds a parent timeout. Native
calls may defer signals. The retained Guile HTTP client cannot forcibly cancel a
stalled upstream operation; two stalled calls can occupy profile slots until they
end, but profile jobs do not hold the message-store mutex. Older legacy synchronous
operations, original image/video decoding and other RC8 limits still apply.

## Executed checks, twice against identical code

Final run 1: `b8eb4fdac35a4b11bcbd72e5392782e9`, completed `2026-09-10T15:06:40.951808+00:00`.
Final run 2: `f1f170f287f449119b2e18a9e5e2bf92`, completed `2026-09-10T15:08:13.256826+00:00`.
All **79 code/build fingerprints** match before and after both runs and the final
candidate. Each Python run: **387 discovered/run; 345 passed, 42 skipped, zero
failures/errors**. The skips are 24 retained and 18 new Guile-dependent HTTP tests,
not successful native integration. The runner labels the suite PARTIAL.

| Check | Both final runs |
|---|---|
| Python suite | PARTIAL: 345 passed, 42 declared Guile skips |
| Structural Lisp shapes | PASS; not an Emacs/Guile compiler or evaluator |
| Retained JSON/envelope/hash benchmarks | PASS; not an RC9 overall speedup comparison |
| New real FFmpeg thumbnail benchmark | PASS; isolated synthetic raster processing |
| FFmpeg capabilities | PASS |
| Source integrity | PASS: 79 unchanged code/build inputs |
| Emacs compilation, ERT, layout and profile benchmarks | BLOCKED: missing Emacs |
| Seven fish entry-point syntax checks | BLOCKED: missing fish |
| Guile unit and three bridge HTTP suites | BLOCKED: missing Guile |
| mpv decode | BLOCKED: missing mpv |
| Rust tests, format and Clippy | BLOCKED: missing Cargo |

The **32 new Python tests pass**, including actual worker subprocesses and local
HTTP, delayed-response deadlines, colon-bearing native-shaped job IDs, one POST,
no resend on failure, capability/metadata redaction, strict input JSON, picture
bounds and real thumbnail transformation. The unchanged 313 passing Python tests
include original-media preservation, audited transactions and existing HTTP/media
regressions. Their success is not native UI or live WhatsApp evidence.

There are **175 supplied ERT tests**, 25 new, including a genuine five-second
loopback response fixture with the real worker and heartbeat/draft assertions.
They were not executed. The 18 new Guile integration tests cover typed events,
job saturation, authentication, revision separation, consent and a real Python
worker talking to the native bridge. They were skipped because Guile is absent.
The graphical fixture captures five actual Emacs PNGs only when run natively;
**no screenshot is supplied or claimed captured in this environment**.

## Actual thumbnail measurements

Seven alternating samples per output size on `Linux-6.18.35-x86_64-with-glibc2.41`, Python
3.13.5, using a declared synthetic raster. Includes FFmpeg process startup;
excludes upstream HTTP, actual photos, Emacs decoding/display and message delivery.
Source bytes remained unchanged; output sizes are unusually small for this simple
fixture and are not representative compression ratios for real photographs.

| Output | Median | p95 | Maximum fixture PNG bytes |
|---|---:|---:|---:|
| 96px | 65.459ms | 71.767ms | 198 |
| 256px | 72.850ms | 74.979ms | 572 |

This is **not** an RC8 comparison, a measured chat-loading improvement, a 100ms
selection guarantee or a process RSS benchmark. Native 1,000/10,000-summary
selection samples and the stated p95 target remain BLOCKED, not inferred from
these worker timings.

## Development history and distribution checks

The complete original baseline audit remains in `evidence/baseline-complete/`.
Earlier interrupted/development runs are retained, not reported as final success.
Structural checking found a delimiter issue in a new ERT cleanup fixture; it was
corrected. Code review found that real bridge job IDs include a colon; worker
validation and the actual subprocess fixture were corrected, and native cross-
component coverage was added. Activation/publication help text was corrected to
require the new bridge too. A run overlapping those edits correctly failed source
integrity; it is not one of the final frozen-code runs above. No test was removed,
skipped or weakened to make a failing behavior appear successful.

`evidence/package-validation.json` records executed package, patch, update and
rollback checks. Low-level transaction fixtures are not a successful native
installation. The production installer retains its exact-candidate **two full
audits** gate; partial, failed or blocked checks cannot authorize replacement.
Any separate actual installer-refusal invocation is labelled with its own reports
and outcome rather than replacing native test evidence.

Complete source is for reproducibility/new installations; the update only copies
managed hash-anchored files. SHA-256 checks prove consistency with this bundle,
not a maintainer signature, third-party attestation or protection against another
process able to rewrite both code and receipts as the same user.

## Activation and remaining acceptance

**RC9 changes the Guile bridge and Emacs client. Restart both actual processes
after successful installation.** The updater does not guess Shepherd/systemd/
Docker services, alter NPM, restart wuzapi, change event subscriptions or pair an
account. Old bridges yield unavailable profile capabilities without introducing
a replacement login. Follow `PROFILES-3.2.0-rc9.md` for update, settings, diagnostics,
separate VPS source activation, native graphical fixture and exact rollback use.

Current dependency advisories, native compilation/ERT/Guile, real mouse/scroll,
actual photographs, live presence permissions/event delivery, microphone/mpv and
recipient delivery remain unverified. No VPS action, remote write/push/tag/release,
real WhatsApp message, account setting mutation or previously declined CI retry
occurred. This is a scoped developer implementation review, not an independent
security certification or assurance that every requested feature works live.

## Primary contract references

- https://raw.githubusercontent.com/asternic/wuzapi/main/routes.go
- https://pkg.go.dev/go.mau.fi/whatsmeow/types/events
- https://pkg.go.dev/go.mau.fi/whatsmeow
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Asynchronous-Processes.html

References describe backend/runtime contracts, not proof of this implementation's
native execution. Installed versions and privacy policy remain decisive.

### Final distribution check results

All **16** package checks passed: full/checksum/payload consistency, actual RC8
preflight, staged configuration/session exclusion and independent PQ preservation,
frozen-byte transaction/exact rollback, unknown/newer edits, payload tamper and
symlink refusal, patch apply/reverse, real check-only commands and whitespace.
The separate **actual guarded installer** completed both full passes, returned
1 with required checks blocked, left **130 existing fixture files unchanged** and
created **zero installation backups**. No native gate was mocked in that run.
See `evidence/package-validation.json` and `evidence/native-install-refusal.json`.

The complete distribution has **142 source files**, **109 managed payloads**,
and **27 changed/new files from RC8**. Current native/live acceptance remains
unconfirmed; these packaging results do not change the release-candidate decision.

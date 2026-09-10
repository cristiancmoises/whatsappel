# WhatsAppel 3.2.0-rc1 — implementation and validation report

Release date: 2026-09-09 (America/Sao_Paulo). Audit UTC: 2026-09-10T00:16:26.864390+00:00.

## Decision

**Release candidate. Native and live acceptance is incomplete. Do not describe this
as a fully audited production release.** The full audit controller returned exit 1:
2 independent gates passed and 13 were blocked by missing executables. The installer
has no skip/bypass switch and will not replace installed source until its native
changed-code checks pass on the destination machine.

## Provenance and change boundaries

The working baseline was the retained, SHA-256-manifest-verified
`whatsappel-upgrade-3.1.0.tar.gz` source snapshot, not an invented repository.
The public Codeberg HEAD could not be retrieved in this environment. GitHub's
connected mirror reported tree/commit `a5af1a66a40dc7d54c3a67c84876d1c5131ba06a`.
Its `whatsapp.el` blob `e0c856b4d8fb54d2a25a823ee169c54b96d2e1e6` matched the baseline
client; its publisher blob `669410e5af62bcb3c91285e18d9f61f7b8983136` also matched.
The baseline client SHA-256 is
`a9e8010a6ee2ac3c920a90d3dd88e5e70d97bbd8b612610cac198c1a2fd9e0bd`.

A whole-repository current-head match is **not** established. The mirror may contain
newer PQ documentation/code than the retained snapshot. Delivery is therefore a
**managed delta**, not a replacement source archive: per-file before/after hashes
refuse unfamiliar edits, and unchanged Guile, wuzapi, pqenv and Org source is not
overwritten. The local Git repository used to make/test the patch is a synthetic
fixture snapshot, not a claim of an upstream commit or publication.

## Executed automated checks

The latest Python regression run discovered **80 tests: 66 passed, 14 skipped,
0 failures**. All 14 skips require unavailable Guile for the real bridge HTTP
suite. The controller separately marks that bridge suite BLOCKED, rather than
using Python's successful exit to claim bridge coverage. The 40 newly added Python
tests comprise 31 worker/installer/unit tests and 9 integration tests.

| Gate | Result | Detail |
|---|---|---|
| python-regressions | PASS | Unittest reported skips; see log. Native bridge HTTP is a separate full-scope gate. |
| emacs-byte-compile | BLOCKED | Missing emacs |
| emacs-ert | BLOCKED | Missing emacs |
| ffmpeg-capabilities | PASS | Exit 0 |
| mpv-local-decode | BLOCKED | Missing mpv |
| fish-apply-update | BLOCKED | Missing fish |
| fish-commit-and-push | BLOCKED | Missing fish |
| fish-deploy-ionos | BLOCKED | Missing fish |
| fish-install-local | BLOCKED | Missing fish |
| fish-publish | BLOCKED | Missing fish |
| guile-unit | BLOCKED | Missing guile |
| bridge-http | BLOCKED | Missing guile |
| rust-tests | BLOCKED | Missing cargo |
| rust-format | BLOCKED | Missing cargo |
| rust-clippy | BLOCKED | Missing cargo |

The real subprocess/fixture coverage includes:

- Original binary attachment bytes and filenames, unsupported-format document
  fallback, response/body/file limits, symlinks/FIFOs, credentials and destination
  validation, private output permissions and guarded rollback transactions.
- Four real loopback HTTP tests using the actual worker child process: one POST
  with exact original bytes; a redirect not followed; malformed JSON treated as
  unconfirmed without retries; server failure not automatically retried.
- Real FFmpeg GIF-to-H.264/MP4 conversion and synthetic Opus encoding. The GIF
  source remains unchanged; conversion is explicit, size/duration/canvas bounded.
  Advertised PulseAudio, libopus, libx264, scale and pad support was also checked.
- A real local Git worktree/commit isolation test: original dirty/untracked files
  were retained and excluded from the publication commit. **That fixture mocks the
  native installer gate to test transaction isolation only**; it is not evidence
  of Emacs, fish or mpv validation, and no remote push was made.
- Archive traversal/link/device rejection and SSH argument quoting checks. These
  do not prove reachability or server configuration on IONOS.

The existing shell audit was also executed in the local Git fixture. Source
whitespace and Bash syntax passed. Its combined publishing target ran the same
Python suite successfully and then returned FAIL because `fish` was absent
(`fish: command not found`, make exit 2). This is recorded as returned, not
silently relabelled PASS. Native client/bridge/Rust checks were BLOCKED; online
RustSec advisories were NOT_RUN. Logs are included under `evidence/legacy-audit`.

There are **18 new ERT cases**, plus 23 existing client and 5 Org cases (46 total).
They were written but **not executed** here. The independent Python delimiter
scanner reported balanced forms; it is **not an Emacs Lisp reader, compiler, ERT
runner, or substitute for those gates**. Python source compilation, patch
application/reversal, package preflight and missing-runtime refusal are recorded
separately in the package-validation evidence.

## Findings addressed in the candidate

Normal text and staged attachment sends no longer do their network upload on the
interactive Emacs path. Duplicate pending sends are rejected and newer draft
edits are retained. A bridge 2xx alone does not clear a draft: upstream
`wuzapi_status` must also be successful. Unknown delivery never triggers an
automatic retry.

Initial chat rendering is bounded to 100 retained messages; Show older expands
already-fetched history. Preview completions are coalesced per buffer, image
specifications are reused within an eight-entry/source-pixel budget, and cache
keys include account/bridge/chat/message scope. PNG/JPEG/static-WebP canvas
headers are checked before native decoding. No end-to-end speedup percentage,
frame-rate benchmark or whole-process RSS bound was measured or asserted.

Media clicks select the event's point rather than a stale cursor location. Video,
audio and GIF playback use shell-free mpv argv and private local snapshots. mpv
configuration/scripts, automatic sidecar loading and external references are
disabled, with a file-only libavformat protocol allowlist. No claim of a complete
decoder sandbox is made. mpv must still be installed and tested on the user's
machine; the installed build may reject an unsupported safety option.

Attachments use a pinned-recipient Preview/Caption/Send/Cancel stage. Recording
starts only from an explicit control, stops at a bounded time, and is never sent
automatically. Original files are not overwritten. Tokens travel to the worker on
stdin, not argv or temporary credential files. Both Python HTTP paths disable
redirects and environment proxies; TLS contexts do not activate SSLKEYLOGFILE
logging from the inherited environment.

Installers use checksummed payloads, before/after content anchors, isolated audit
candidates, curated atomic writes, private rollback journals and newer-edit
refusal. The IONOS transfer retains SSH host-key verification and validates its
archive before extraction. Publication uses a separate worktree and the existing
host/repository-scoped hidden-token publisher, without force pushes, broad staging,
remote URL rewrites, implicit repository creation or visibility changes.

## Explicit limits and unexecuted acceptance

Graphical launch, actual mouse behavior/zoom, mpv GUI controls, physical microphone
permissions and capture, actual WhatsApp pairing and delivery, IONOS access,
all four real pushes and current dependency advisories were **not executed**.
No screenshot, connected-session result or production deployment is fabricated.

The following are deliberate scope limits, not completed features:

- This is a mouse-first **Emacs desktop** workspace, not a browser application.
  Updating only VPS source cannot change an Emacs already running on the laptop.
- Guile/wuzapi and pqenv are not changed or restarted. Existing Connect, QR, Sync,
  Save, Forward, encrypted text and Org low-level paths retain synchronous work.
- Voice is Opus audio through the existing audio route, not a newly implemented
  native PTT flag/voice-note badge. GIF conversion uses the existing MP4 video
  alias; a native WhatsApp GIF-loop flag is not guaranteed.
- Ordinary media is not newly wrapped in pqenv. The changed UI must not be read as
  a new cryptographic guarantee. No PQ audit is claimed from unchanged code.
- Image headers and limits reduce selected risks but do not prove the safety of
  every crafted image/video, codec library or native Emacs decoder. In-memory
  image caches and Emacs display references can use memory beyond declared source
  bytes. Some legacy operations and polling responses remain potential bottlenecks.
- The desktop launcher retains normal Emacs init, so user configuration may affect
  startup, keybindings, images, connectivity and available package versions.

## Reproduction and references

From a complete updated checkout:

```fish
python3 scripts/audit-workspace.py . --scope full
```

From the extracted update package, the default installer command only verifies
compatibility; adding `--apply` runs its native changed-code gate before writes.
The full controller keeps Guile/Rust checks independent of that client-only gate.

Implementation references consulted (no external source is evidence that these
changes passed local execution):
- mpv reference manual: https://mpv.io/manual/master/
- FFmpeg device documentation, PulseAudio input: https://ffmpeg.org/ffmpeg-devices.html#pulse
- Repository architecture: https://github.com/cristiancmoises/whatsappel

This is a developer implementation review with reproducible evidence, not an
independent penetration test, security certification or guarantee of correctness.

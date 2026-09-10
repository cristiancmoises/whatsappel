# WhatsAppel workspace engineering specification

Act as the maintainer of a security-conscious Emacs Lisp / Guile application,
with responsibility for UI usability, media processing, regression testing,
reversible deployment and accurate release evidence.

## Objective
Improve the existing WhatsAppel client, not a replacement mockup. Preserve its
Emacs + Guile + wuzapi architecture, existing Org commands, shared-token bridge
contract, session data, optional pqenv identities and licensing. Make routine
conversation and attachment actions accessible through visible controls.

## Inspect before editing
Read the actual source and tests. Establish exact content hashes and the source
provenance. Use the user's retained 3.1.0 upgrade only after checksum verification;
compare the live mirror's client blob before building on it. Do not pretend a
mirror proves Codeberg HEAD. Refuse unfamiliar installed file hashes rather than
resetting, overwriting or guessing a migration. Preserve unrelated concurrent work.

## Implementation
1. Move interactive text sending and attachment upload off the synchronous UI path.
   Block accidental duplicate sends while a request is pending. Preserve newer
   drafts and replies. Treat missing confirmations/timeouts as unknown delivery;
   never silently retry a potentially delivered message.
2. Bound initial message rendering and image memory work. Offer Show older, cache
   reusable image specs, scope media by account/origin/chat, and coalesce repaints.
   Do not fabricate latency or speedup measurements when Emacs cannot be run.
3. Make image activation select the clicked message. Add fit, zoom and original-byte
   saving, with byte/canvas limits before decoding. Unsupported formats must fail
   safely rather than execute documents or relabel unknown data as supported media.
4. Use mpv through an argument vector, never a shell. Disable user configuration,
   autoloaded scripts, URL extractors and external references. Play private snapshots
   and retain them until the owned player exits. Test with a local generated fixture
   when mpv exists; distinguish headless decoding from graphical usability.
5. Add a desktop launcher, sidebar, explicit Image/Video/GIF/Voice/File controls and
   a recipient-pinned Preview/Caption/Send/Cancel stage. Record only after an explicit
   click. Stop and flush recording; never auto-send microphone output. Preserve
   original files and require an explicit action to prepare a GIF as an MP4 copy.
   Do not promise native PTT/GIF badges that the existing bridge does not implement.
6. Keep the GUI on the workstation. Do not disguise an Emacs interface as a web
   server or modify Nginx Proxy Manager, Docker ports, firewalls or wuzapi sessions.
7. Generate fish entry points and complete Python helpers for hash-checked updates,
   native candidate audits, rollback, SSH transfer to root@securityops.co:5119,
   isolated commits, and publication to the user's four exact repository paths.
   Keep host-key/TLS verification enabled. Do not place tokens in argv, Git URLs,
   credential files, logs or shell history. Use hidden terminal input and the
   repository-scoped in-memory credential helper. Never force-push or auto-merge
   divergent remotes. Continue reporting independent forge failures accurately.

## Verification and reporting
Run all feasible existing and new tests in this session: Python unit and loopback
integration, safe extraction, file/credential validation, real FFmpeg fixtures,
Git worktree isolation and rollback. Attempt native byte-compilation, ERT, Guile,
fish, mpv and Rust checks. An unavailable runtime is BLOCKED, not PASS; a skipped
suite is not silently counted as executed. Include exact logs, test counts and
limitations. Run patch round-trip/hash validation and checksum every deliverable.
Keep the update as a release candidate until native and live acceptance gates pass.

## Deliverables
A full-index patch; changed source files; content-anchored manifest; test suites;
English and pt-BR documentation; audit evidence; fish installation, deployment and
commit/push entry points with every required helper; rollback support; archive
and SHA-256 checksum. State explicitly what was changed locally and what was not
pushed, deployed, paired, recorded or tested against real accounts.

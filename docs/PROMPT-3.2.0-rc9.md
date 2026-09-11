# WhatsAppel — native UI/UX, avatars, truthful presence, and responsiveness

## Mission

Act as the maintainer implementing a focused, production-minded improvement to WhatsAppel, not as a mockup generator. Improve the actual Emacs application so it is visually coherent, easy to operate with a mouse, efficient with a keyboard, and closer to telega's conversation workflow. Add real profile photographs and capability-aware presence without reintroducing the reported freeze when selecting a contact.

Project: https://codeberg.org/berkeley/whatsappel
Existing installation: ~/whatsappel on GNU Guix; shell: fish.
Architecture to preserve: Emacs Lisp client, Guile bridge, Python workers, wuzapi/whatsmeow transport, mpv/FFmpeg media tools, and optional pqenv. Preserve the existing license, account settings, sessions, keys, local edits, and installer safeguards.

The most recently supplied candidate in this conversation is 3.2.0-rc8. Treat that as a reference, not proof of the installed or remote version. The screenshot shows an OLDER, deliberately censored interface. Do not reconstruct hidden content, use private contacts as fixtures, or treat censorship as a rendering defect.

Success means working code, native validation, real fixture-based screenshots, measured responsiveness, readable EN/PT-BR documentation, and a guarded update package. Do not claim implementation or test success for unfinished work.

## 1. Establish the baseline and capability contract first

Inspect the actual checkout, committed HEAD, dirty/untracked files, manifests, deployed bridge version when accessible, and loaded Emacs source/version. Compare retained candidates only by exact hashes. Do not overwrite unknown edits, switch the active checkout, or assume mirrors are identical. Select the next unused release-candidate version; do not reuse an existing artifact filename for different source.

Trace the actual code paths for contact selection, root rows, history updates, preview loading, worker IPC, profile metadata, webhook dispatch, and presence. Relevant RC8 entry points include whatsapp-open-chat, whatsapp-root--insert-row, whatsapp-root--update, whatsapp-root--select-only, whatsapp--poll, whatsapp--preview-image, and whatsapp-selection-diagnostics. Verify names in the real tree rather than inventing replacement APIs. Inspect whatsappel.scm, scripts/read-worker.py, scripts/media-worker.py, existing tests, and the audit/installation tools.

Produce a capability matrix covering profile thumbnails, full photographs, profile-change events, incoming presence, last seen, typing/recording, profile About text, group photos, and supported identity formats. Record exact upstream versions, routes, HTTP methods, event payloads, and privacy/error behavior. Source code and contract tests take precedence over stale example commands.

Reference warning: upstream wuzapi API.md described /user/avatar as GET when checked, whereas its routes.go registered POST. Verify the installed version. Do not blindly copy a GET-with-body example or probe write-like routes repeatedly. Missing capability must become an explicit fallback, not a fabricated endpoint or status.

Do not assume an outgoing presence API subscribes to another person's presence. Keep subscription, incoming events, outgoing self-presence, and typing announcements separate.

## 2. Redesign the native workspace, not the entire application stack

Retain a native Emacs interface. Do not introduce Electron, a browser frontend, Node/Baileys, or a mandatory webview. Use telega as interaction inspiration rather than assuming Telegram features exist in WhatsApp.

Build a responsive two-pane workspace on wide frames: a resizable conversation sidebar approximately 34–44 columns wide and an active conversation pane. Narrow frames should use a single-pane layout with an obvious Back to chats action. Opening WhatsAppel should not destroy unrelated Emacs window layouts; restore an owned workspace predictably on exit.

Use a restrained black/near-black and cyan presentation, readable foreground text, clear selected rows, consistent spacing, and visible keyboard focus. Make faces customizable and scoped to WhatsAppel. Respect existing themes and accessibility settings. Avoid blinking presence indicators, expensive glow effects, heavy animation, and mandatory icon fonts.

Each normal conversation row should reserve a fixed avatar area and align name, timestamp, unread badge, short preview, and small pin/mute/group indicators. Supply comfortable two-line and compact one-line modes. Missing photos must not change row geometry. Do not repeat large action buttons throughout the transcript or add decorative symbols that hide useful text.

Disable code-oriented line numbers, fill-column indicators, and inappropriate wrapping locally in app-owned UI buffers where appropriate; never change global editor settings. Make display text robust to long names, combining marks, emoji, RTL text, large fonts, and long message previews. Keep full values available through explicit details/copy actions without inserting arbitrary text properties or interpreting contact strings as code.

The conversation header should contain the selected contact's avatar, name, truthful presence, and labelled Search, Media, Contact info, and More actions. Clearly separate global bridge/transport health from that contact's state. Group headers show group information, not a fabricated group-wide online state.

## 3. Implement an asynchronous avatar pipeline

Display authentic user/group photographs only when returned through the authenticated account's supported backend. Use initials or a neutral group symbol immediately while a photo is loading, absent, hidden, unsupported, or temporarily unavailable. Never invent an identity or search the public web for a contact's photo.

Load thumbnail metadata and bytes asynchronously. Request only the selected contact and a bounded visible sidebar range, not every cached contact. Deduplicate requests across sidebar/header/details views. Keep photo work lower priority than sending, reading messages, and switching conversations. Bound both active tasks and queued tasks; start with two active photo jobs and a small fixed queue, then justify any adjustment with measurements.

Reserve dimensions before loading: approximately 36–40 logical pixels in comfortable rows, smaller compact thumbnails, and 56–64 logical pixels in the header. Maintain aspect ratio. Rounded presentation is optional only where it can be implemented without costly synchronous conversion; use an aligned raster fallback otherwise. A terminal frame gets initials/text, not broken image controls.

Use account-scoped metadata, encoded-byte, and decoded-thumbnail caches with explicit entry, byte, and pixel budgets. Never use raw tokens in filenames, logs, or public cache keys. Reuse backend picture identifiers/versions when supported. Cache legitimate missing-photo results for a short bounded interval. Invalidate changed, removed, privacy-restricted, and account-switched photographs correctly. A transport failure is not evidence that the person blocked the user.

Keep cache persistence off by default unless an existing protected cache policy already governs it. Any optional disk cache needs private directories/files, atomic writes, symlink refusal, bounded retention, and an explicit Clear profile cache control. A privacy/removal event must stop displaying the old image; temporary network failure may retain a clearly identified cached image.

Clicking a photograph opens a contact details view with a larger, lazily loaded photo and close/back controls; clicking the rest of its row selects the chat. Neither action sends a message or changes privacy settings. Do not expose signed CDN URLs to users, process arguments, or logs unnecessarily.

Fetch avatar bytes through a controlled, authenticated bridge/worker path. Validate supported HTTPS destinations, redirects, DNS/address resolution, byte limits, signatures, MIME, and image dimensions. Prevent user-controlled URLs from becoming an SSRF primitive; reject private, loopback, link-local, multicast, and metadata destinations for CDN fetches without breaking the separately configured loopback bridge connection. Avoid validation followed by an unrelated DNS re-resolution. Never forward bridge/wuzapi credentials to the photo CDN.

Do not decode untrusted full-resolution images in selection handlers, mode-line evaluation, or ordinary transcript rendering. Prefer bounded thumbnail processing in an owned worker with deadlines and output limits; admit only validated thumbnails to native display. Do not describe header inspection or deferred decoding as a complete decoder sandbox.

## 4. Show presence honestly and respect privacy

Implement an explicit, account-scoped state model with separate fields for transport health, observed remote availability, last-seen timestamp, typing/recording activity, local observation time, freshness, and capability/privacy/error state.

Display Online only following a supported positive presence event. Show Offline only when supported current evidence permits it. If information is missing, stale, unsupported, or hidden, use Unknown, Status unavailable, or an accurate equivalent. Never convert time since the last message, missing webhook events, a healthy bridge, or a delivery receipt into a claim that a contact is online or offline.

Remote Idle/Away is not a status to fabricate from silence. Implement it only if the verified backend explicitly reports that state. Otherwise document the limitation and offer truthful last-seen/activity information. A local idle timer may label the user's own Emacs inactivity as Local idle, but it is not the other person's state or proof of WhatsApp-wide presence.

Last seen must come from the authorized backend. Hidden/missing timestamps remain unavailable; do not infer them. Typing and Recording audio need short-lived activity states that expire independently and never become stuck permanently. Do not misinterpret a paused typing event as offline or idle.

Subscribe narrowly to the selected direct chat and, only when justified and enabled, a bounded set of visible direct contacts. Handle reconnects, duplicate/out-of-order events, identity mapping, freshness expiry, and unsupported subscription mechanisms. Do not invent an unsubscribe route; document limitations of the installed backend. Bound retained presence data and avoid persistent presence histories or background contact tracking.

If receiving presence requires publishing this account as available, explain that privacy effect and require an explicit user setting. Do not silently force the account online, change privacy settings, or start outgoing typing announcements to make indicators work. Existing backend behavior must be surfaced accurately rather than claimed absent.

Distinguish presence from profile About text and from WhatsApp Status/stories. A contact-info panel may display authorized About text. Stories are outside this iteration unless separately implemented and tested; do not advertise them based on a status field name.

## 5. Extend the bridge and workers without blocking normal traffic

Add typed handling for supported profile/presence events instead of forcing every webhook through the message parser. Preserve existing Message subscriptions and webhook settings when adding supported events; do not reset or reconnect a live account automatically. Validate authentication, account scope, event sizes, field types, and identity formats before updating state.

Expose small versioned capability/metadata responses. Keep photo bytes out of ordinary /chats snapshots. Separate profile/presence revisions from transcript revisions so a presence burst does not retransmit history, rebuild chat summaries, or reset unread counters.

Keep outbound profile lookups and subscriptions away from the bridge's synchronous request bottleneck. Use bounded asynchronous jobs or an equivalent measured implementation. Never hold message-store locks while doing upstream I/O, decoding images, or serializing large responses. Prioritize user work; degraded avatar/presence providers must not delay text sends or normal history reads.

Update the Python worker route allowlist, strict schemas, deadlines, response bounds, and tests for every new bridge contract. Preserve credential pairing, TLS verification, no-redirect policy, and no automatic resend of uncertain messages. Capability failures should disable only the unsupported feature with a useful explanation.

## 6. Preserve and strengthen the contact-selection responsiveness work

Selecting a contact must show a usable header/composer immediately from local state. It must not synchronously wait for network replies, profile downloads, image conversion, history expansion, decryption, or subprocess completion.

Preserve RC8's generation/account/buffer-lifetime guards, deferred opening, bounded long-message previews, explicit asynchronous Decrypt, original-message data, and property-only selection updates. Do not restore automatic decryption merely for visual convenience.

A timer is deferred main-thread work, not a background thread. Keep callbacks, JSON parsing, and process filters bounded; move expensive processing into owned workers. Avoid new synchronous url-retrieve-synchronously, call-process, shell-command, sleep, or unbounded accept-process-output loops on interactive paths. Do not compensate by disabling garbage collection indefinitely.

Patch only the affected avatar/status/row/header region when possible. Preserve draft text, point, undo state, reply target, scroll anchor, and selected conversation. Presence must not reorder the list or mark chats read. Coalesce bursts and do no repeated rendering work in hidden/iconified frames. Shut down owned jobs/timers on buffer closure and reject late results from previous accounts/selections.

## 7. Make common tasks discoverable without sacrificing keyboard use

Provide visible Send, Attach, Record voice, Emoji, Search, and Back/Latest controls with useful labels/tooltips and keyboard equivalents. Preserve existing bindings, particularly the configured send/newline behavior and Forward. Do not silently change Enter semantics or permit image/avatar clicks to send drafts.

Keep attachment staging recipient-pinned: choose file, preview/caption, explicit Send or Cancel. Retain mpv playback and recording Start/Stop/Preview/Send. Show progress, cancellation, and errors inline without changing recipients or triggering automatic retries. Do not claim native PTT/GIF-loop semantics that the backend does not support.

Add a contact details panel with photo, display name, permitted About/last-seen data, identity information, and supported actions. Dangerous operations need confirmation. Add accessible settings for density, avatar loading/cache, presence privacy, font scale, and theme choice. Use text as well as color for status and errors.

Keep the desktop launcher and normal Emacs entry point. Add an offline synthetic demo mode only if useful for testing/screenshots; mark it unmistakably as demo and prevent all network/send actions. Never populate the live account with sample chats.

## 8. Validate native behavior, not just source shape

Run the existing complete suite before changes and record actual baseline failures. Add tests while implementing, then run the full audit twice against the exact final code. Retain failures and corrections in the evidence. Do not remove assertions, introduce skips, or relax privacy/validation guards to achieve green output.

Required ERT/native coverage: immediate composer activation with a five-second delayed profile server; actual mouse and Return targeting; rapid A→B→A selection; stale account callbacks; multiframe/hidden-window behavior; draft/undo/scroll preservation; no per-event root rebuild; missing-photo fallback; thumbnail completion; contact-details close/back; bounded large Unicode rows; keyboard-only and terminal operation; cleanup after cancellation and buffer closure.

Required Guile/Python integration coverage: real fixture HTTP for avatar metadata/bytes; auth and cross-account rejection; Message plus presence/profile webhook routing; bounded jobs and saturation; changed/removed/hidden photos; absent or malformed last seen; duplicate/out-of-order presence events; reconnect expiry; unsupported backend capability; no automatic self-online; separate transcript/presence revisions; no history or send starvation during stalled image work.

Required security coverage: oversized/deceptive/corrupt images, prohibited address destinations and redirects, DNS rebinding defenses, credential leakage, symlink/cache races, duplicate/nonfinite/oversized JSON, malicious display strings, expired jobs, and unauthorized cache lookup. Exercise the actual relevant process/network paths; label mocks as mocks.

Use a declared synthetic performance fixture of 1,000 and 10,000 cached chat summaries and 60 visible message records. Treat the larger client fixture as stress input, not a promise about bridge retention. Measure cold/warm selection, initial useful display, event-loop heartbeat, row updates, cache hit rate, queue depth, CPU, allocations/RSS, and long-session cache bounds. Report environment, raw samples, medians, p95, and worst observed pauses. Separate selection, provider latency, decoding, rendering, and recipient delivery.

Set explicit regression budgets before comparing builds; a suggested target is under 100 ms p95 for cached selection/composer activation on the declared test machine, with no UI waiting on a five-second fixture response. Treat this as a test target, not an achieved measurement or universal latency guarantee. Investigate regressions rather than hiding slow samples or silently relaxing limits.

Run the real graphical client with synthetic data at narrow/wide widths and different font scales. Capture actual Emacs screenshots after execution; do not substitute an HTML mockup or generated image. Verify labels, focus, text wrapping, avatar fallbacks, loading/errors, and keyboard accessibility. Headless native tests, GUI smoke tests, provider integration, and real-account acceptance remain distinct.

If native tools are unavailable, mark their gates BLOCKED and supply the exact local command. Do not call Python-only passes a successful Emacs/Guile audit. Preserve the updater's refusal on required failures, partial coverage, or missing runtimes. Never send real test messages or manipulate a real contact's state without explicit authorization.

## 9. Deliver a reviewable, safely updatable release candidate

Supply the complete source archive, incremental review patch against the verified baseline, managed update payload, checksum manifests, provenance, changelog, EN/PT-BR READMEs and usage guides, actual screenshot assets, and two exact-source audit reports. Include a feature matrix: implemented, executed in native tests, verified against fixture backend, manually verified, unsupported, or blocked.

Keep documentation specific: distinguish installed files from running Emacs code, bridge connection from remote presence, privacy-hidden from offline, unavailable photo from blocked contact, and thumbnail caching from secure deletion or encryption. Explain every dependency and capability requirement.

Provide one complete fish update command for the existing ~/whatsappel GNU Guix installation that stages, audits twice, and installs only on success. Preserve .env, session/PQ state, independent edits, private backups, and rollback refusal for newer changes. Do not require reinstalling the operating system, guix pull, sudo, or copying source/ over the live tree. Version runtime strings, source, manifests, tests, launcher, and docs consistently.

If bridge changes are needed for these features, separate workstation-client and VPS-bridge update/activation instructions. The known VPS destination is root@securityops.co, SSH port 5119; discover the real service only with authorization, retain host-key verification, and do not touch NPM or unrelated containers. A client-only file update cannot activate a new server contract.

Retain isolated, non-force publication scripts for:
- https://git.securityops.co/cristiancmoises/whatsappel.git
- https://git.securityops.com.br/cristiancmoises/whatsappel.git
- https://github.com/cristiancmoises/whatsappel.git
- https://codeberg.org/berkeley/whatsappel.git

Use hidden token prompts and repository-scoped credentials; never put tokens in URLs, argv, logs, or committed files. Preserve the original working tree. Provide scripts but do not push, deploy, restart services, create remote branches/tags/releases, or retry the previously declined CI workflow write without new explicit authorization.

Finish with actual changed behavior, compatibility limits, measured results, exact test outcomes, installation/activation/rollback commands, and remaining live acceptance. Do not describe an attractive screenshot, deferred callback, or successful HTTP acknowledgement as proof that everything works.

## Primary technical references — verify against the installed versions

- telega native workflow: https://zevlg.github.io/telega.el/
- wuzapi routes: https://github.com/asternic/wuzapi/blob/main/routes.go
- wuzapi handlers: https://github.com/asternic/wuzapi/blob/main/handlers.go
- wuzapi API guide: https://github.com/asternic/wuzapi/blob/main/API.md
- whatsmeow profile and subscription APIs: https://pkg.go.dev/go.mau.fi/whatsmeow
- whatsmeow presence/profile events: https://pkg.go.dev/go.mau.fi/whatsmeow/types/events
- Emacs asynchronous processes: https://www.gnu.org/software/emacs/manual/html_node/elisp/Asynchronous-Processes.html
- Emacs timers: https://www.gnu.org/software/emacs/manual/html_node/elisp/Timers.html

These references inform contracts and design; they are not evidence that this project's implementation passed tests.

## Execution scope note

Implementation continues from the exact retained RC8 archive. Native runtimes
remain unavailable in this container. The delivered report must distinguish
implemented source, actual Python/HTTP/FFmpeg execution, supplied native tests,
blocked graphical capture, and unverified live provider behavior. Do not fabricate
screenshots, deployment, remote capabilities or a native selection timing.
Memory-only cache and explicit bounded subscription were chosen; persistent cache,
remote Idle/stories, new PN/LID mapping, and automatic provider reconfiguration
are outside this candidate. Existing sidebar behavior is retained, not rewritten.

# WhatsAppel 3.3.0

Native WhatsApp workspace for GNU Emacs, with a Guile bridge, bounded Python
workers and the wuzapi/whatsmeow provider. Contact photos, confirmed archive controls and native conversation tools.

## Photos and conversation tools

Photos appear beside contacts in graphical Emacs; initials remain available in
terminals. Photo work follows visible graphical frames, including daemon clients.
Press `i` on a contact for a larger photo, refresh, retry and profile diagnostics.

The Inbox hides conversations archived through this client. Press `a` to archive
or restore on WhatsApp, `P` to pin locally, and `m` (or right-click) for chat tools.
Use the Archived and Pinned filters, or `M-x whatsapp-show-archived`. Archive changes
wait for the provider's success response; failed or timed-out requests keep the
current view. Pins and confirmed archive choices survive Emacs restarts in private,
account-scoped JSON. Archive changes made on another device are not imported yet.

`M-x whatsappel` is an alias for `M-x whatsapp`. See [Usage](docs/USAGE.md) for
configuration and shell aliases. The release includes the RC18–20 reliability fixes.

## Session recovery and truthful status

The connection panel now distinguishes the bridge from the WhatsApp backend.
Cached history remains usable while a separate, account-scoped label reports
backend readiness. **Connect existing session…** is an explicit, confirmed action;
its HTTP acknowledgement is not login or delivery. It preserves known event
subscriptions and never logs out, deletes sessions or resends messages.

Use **Open linking QR** only when the backend needs login. Callback registration
and per-contact Presence consent remain separate choices. The new read-only
`python3 scripts/doctor-session.py --source "$HOME/whatsappel"` diagnostic reports
safe state labels. Add `--probe-recent-image` to request one bounded media sample;
it refuses that sample until a fresh backend check reports connected and logged in.

[Session recovery guide](docs/USAGE.md) ·
[Guia de recuperação](docs/USAGE.pt-BR.md)

## Retained photo, media and presence fixes

RC18 moves media-download submissions to a bounded no-proxy worker, uses existing
authoritative LID mappings for profiles, preserves safe photo-failure categories,
and adds explicit profile-event registration to the connection panel. Last-seen
observations are kept separate from current presence. Consent, privacy, account
boundaries, original send-recipient identities and the no-resend policy remain.

[Repair and update guide](docs/USAGE.md) ·
[Guia em português](docs/USAGE.pt-BR.md) ·
[Usage](docs/USAGE.md) · [Troubleshooting](docs/USAGE.md)

## Existing GNU Guix installation

Download `whatsappel-3.3.0.zupt` and `SHA256SUMS` from the release, then verify and
extract the archive using [ZUPT](https://github.com/cristiancmoises/zupt):

```sh
sha256sum -c SHA256SUMS
zupt test whatsappel-3.3.0.zupt
zupt extract -o extracted whatsappel-3.3.0.zupt
cd extracted/whatsappel-3.3.0
```

Within the extracted bundle:

```fish
fish scripts/update-and-activate.fish "$HOME/whatsappel" --restart-local
```

Both full native audits must pass before installing. The active source, service,
account and listener must match before a local Shepherd restart is allowed.
Your private `.env`, sessions, init and PQ identity are not replaced.
After success, save your buffers and completely restart Emacs/its daemon.
Do not run this bundle command from an unrelated repository checkout.

A complete source archive is also included for review. It is NOT an instruction
to copy the whole tree over private state. Unknown runtime edits are refused.

## Native interface

![Chat list](docs/screenshots/whatsappel-root.png)
![Conversation and accepted send](docs/screenshots/whatsappel-accepted.png)
![Workspace settings](docs/screenshots/whatsappel-settings.png)
![Inline images](docs/screenshots/whatsappel-image-view.png)
![Conversation media](docs/screenshots/whatsappel-media.png)

These are the previously approved screenshots; they are not new 3.3.0 acceptance
results. Image files are unchanged from the approved clean distribution.

## Validation

Run `python3 -I scripts/audit-workspace.py . --scope full` for the complete audit.
`make check` includes the native regression suites. A passing fixture does not
establish live recipient delivery, graphical rendering on every machine, or
availability of private profile data. Release validation evidence is included as JSON in the update bundle.

Static images require an appropriate graphical Emacs build. FFmpeg prepares
thumbnails. Choose mpv explicitly in Settings for external playback. Installing
PALE separately does not implement the still-missing WhatsAppel PALE adapter.
Provider acceptance is not recipient delivery. Unknown presence is not idle/offline.

## Source and license

- https://codeberg.org/berkeley/whatsappel
- https://github.com/cristiancmoises/whatsappel
- https://git.securityops.co/cristiancmoises/whatsappel
- https://git.securityops.com.br/cristiancmoises/whatsappel

AGPL-3.0-only. See [LICENSE](LICENSE).

# RC8: responsive contact selection

## What changed

Selecting a contact now creates/displays the composer before a 50 ms deferred callback
starts refresh. It does not send a message. A new selection, changed account or closed
buffer invalidates old deferred opening work. Selecting another contact updates only
selection faces; it no longer rebuilds contact rows on that path.

Text previews are 2,048 characters by default (hard maximum 8,192 per message).
Original records are untouched. **Read full text** opens local 8,192-character pages.
Copy text continues using the original message/caption. Sender and caption previews
are separately bounded. Explicitly loading very large history windows can still cost
time; this is not constant-time processing of arbitrary account data.

Transcript rendering reuses ready image specs but does not decode new ones. Preview
work uses wall-clock timers, does not request forced redisplay from scroll callbacks,
and decodes at most one ready visible image per tick. Individual native decoders can
still block and are not sandboxed by this change. Save original and mpv remain available.

Uncached encrypted messages now show **Decrypt**. This is a deliberate usability change:
opening a conversation no longer runs synchronous pqenv operations for each message.
Decrypt runs one owned child per chat, with a ten-second deadline, 1 MiB ciphertext and
stdout caps, 64 KiB stderr cap, private ciphertext temporary files and no automatic retry.
Signature verification, replay handling and --max-age are retained. Plaintext is kept
in memory and scoped to the bridge/account; Org capture uses that same key. This does
not add attachment encryption or assert new cryptographic security. A cancelled or
failed invocation can already have updated pqenv's replay state; the UI never retries
it automatically. Key setup and explicit legacy encrypted sends remain unchanged.

## Upgrade on GNU Guix

Download the archive and its checksum, then run in fish:

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc8.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc8.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc8/scripts/update-guix.fish" "$HOME/whatsappel"
```

This uses the existing native toolchain, stages a candidate, runs both full audits,
and replaces only recognized managed files after success. It does not perform guix
pull/reconfigure, reset accounts, restart services, or push. The package supports
explicit recorded earlier hashes and RC7, not unknown edits or every historical RC3
variant. Current remote HEAD has not been verified. Use --check or --audit-only for
non-installing operation; do not run with sudo. Keep the printed rollback backup.

After success, restart the WhatsAppel Emacs instance and launch:

```fish
"$HOME/.local/bin/whatsappel"
```

RC7 to RC8 does not change the Guile bridge. Updating client source on a VPS does not
change Emacs already running on a workstation. A cumulative upgrade from before RC2
also includes the older bridge update, which requires restarting its actual launcher.

## Check the running client, not just the files on disk

Run **M-x whatsapp-selection-diagnostics** in a conversation. The output includes the
loaded RC8 version, Emacs version, source directory, selection-command elapsed time,
cache counts and pending-read flags. It excludes message text, recipient IDs, tokens
and bridge URLs. The measured selection-command time is NOT network delivery latency
or total frame-render time. No command here sends a test WhatsApp message.

If Emacs still freezes, enable **M-x toggle-debug-on-quit**, select the same contact,
and press **C-g**. Save/review the debugger backtrace before sharing: unlike the compact
diagnostic, a backtrace can contain contacts, message text or credentials. Toggle the
option off afterward. A backtrace is required to identify a remaining live bottleneck
rather than assuming it is the same code path removed in this patch.

## Publication and retained scope

```fish
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
and fish scripts/push-four.fish
```

These use the isolated ~/whatsappel-publish-3.2.0-rc8 checkout and the same four
repository-scoped hidden-token remotes. No publication is executed by the update.
No force push or implicit repository creation is introduced.

Native ERT/Guile, real graphical acceptance, microphone/mpv and real message delivery
remain distinct gates. See AUDIT-3.2.0-rc8.md for actual results, not promised results.

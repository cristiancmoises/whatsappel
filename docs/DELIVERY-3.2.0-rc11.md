# RC11 — diagnose the live path, then apply guarded repairs

**Candidate, not a claim of repaired live phone delivery.** RC10 and the supplied
init were inspected locally. The running provider, bridge, loaded Emacs and phone
were not connected to this preparation environment. Source defects are not proof
that every symptom on that installation has the same cause.

## First: a read-only report, even before installation

From the extracted RC11 bundle:

```fish
python3 scripts/doctor-delivery.py --config "$HOME/whatsappel/.env" \
    --output "$HOME/Downloads/whatsappel-delivery-"(date -u +%Y%m%dT%H%M%SZ)".json"
```

It makes bounded GETs only: /health and, on an old bridge, /status; on RC11 it uses
/transport/status. It does not send messages, mark read, connect, repair, or
change provider configuration. The private, new-only output contains booleans,
HTTP status, counts and safe versions, not tokens, names, JIDs, URLs or raw replies.
An old /status may carry provider secrets: these stay transiently in memory and
are never copied into the report. Provider-side logging remains outside this
client's control. A doctor report is diagnostic information, not an attestation.

Use --url only for the actual client-accessible origin. A URL is not a token
argument. A missing token can be entered through hidden input. An existing .env
must remain a private, regular, user-owned literal settings file.

**BRIDGE_URL and PUBLIC_URL have opposite directions.** BRIDGE_URL is where
Emacs connects. PUBLIC_URL is where wuzapi calls back. An explicit BRIDGE_URL
wins; otherwise local HOST/PORT is mapped from bind wildcard to loopback.
PUBLIC_URL alone is refused rather than silently treated as a client origin.
Remote client access requires explicit HTTPS or a loopback SSH tunnel. A bare
environment token still deliberately selects the loopback default, not a token
from one account joined to another source's URL.

## What the patch changes

- A real provider message ID is required for acceptance, in the bridge, upload
  worker and normal text worker. Ambiguous replies keep the draft and are not
  resent automatically. Accepted, delivered and read are distinct labels.
- Matching authenticated ReadReceipt events promote existing own-message records
  monotonically; unknown receipts create neither conversations nor unread counts.
- Direct JSON, one jsonData JSON envelope, form jsonData, and bounded binary
  multipart jsonData are handled. Binary file parts are not decoded as UTF-8 or
  saved using remote filenames. Duplicate keys/metadata are rejected.
- Ordinary ephemeral and document-caption message containers retain downloadable
  metadata. View-once containers are deliberately not unwrapped.
- Image failures no longer become a permanent successful `done` state. Retry
  images clears failed work for the current conversation and retries only visible
  items. It does not resend a message or recover media absent from upstream.
- New Check delivery panel reads connection/login/callback/subscription state and
  incoming counters without exposing the underlying provider payload.
- Native static-image viewing remains; explicitly opened bounded GIFs animate
  inside Emacs and stop when hidden/closed. Returning to a paused viewer uses Play.
  GIF input: 4 MiB, 2048 per edge, 120 frames, 8 million canvas-frame pixels.
  These bounds do not sandbox the native GIF decoder. WhatsApp's MP4-based GIFs
  remain videos, not this native-GIF path.

## Pale: explicitly unfinished

The requested default preference is **Pale**, not mpv. **There is no working
Pale binding in this build.** The actual upstream source/API could not be
retrieved. The UI says unavailable and launches nothing; it does not invent a
Pale function or silently open mpv. This means default video playback is blocked
until the verified binding exists or the user explicitly changes the setting.

Settings → Video → mpv enables the existing owned, shell-free mpv playback.
`M-x whatsapp-video-select-backend` also changes it for this session. Persist the
choice with Customize (`whatsapp-video-backend`) or an explicit init setting.
Static images/native GIFs are not implemented using Pale. Audio retains its
explicit mpv playback. No automatic player/native-module installation occurs.

## Single guarded Guix update

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc11.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc11.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc11/scripts/update-guix.fish" "$HOME/whatsappel"
```

Do not use sudo, delete earlier bundles, or copy source/ over installed source.
The cumulative updater accepts only recorded hashes, stages privately, runs two
full audits, and installs only after both reports and source hashes agree.
Configuration, sessions and independently newer PQ code are preserved. No Guix
profile mutation, background upgrade, automatic commit, or service restart.

## Activation is essential

**Restart both the actual Guile bridge and the WhatsAppel Emacs instance** after
successful installation. `whatsappel-transport.scm` must be installed alongside
`whatsappel.scm`. Merely installing the client on the laptop does not update a
bridge running on IONOS. The new init tabs also do not start/repair the bridge.
No service/container name is guessed. The included IONOS script retains SSH
host-key verification and port 5119; transfer alone does not activate code.

Open Check delivery. `Connection: no` or `Login: no` requires investigating the
existing provider session, not retrying chat sends. For a callback/subscription
mismatch, use **Repair incoming callback…** and confirm the action. It GETs
verified provider configuration, preserves all subscriptions, adds Message and
ReadReceipt, writes once, and GETs again to verify. It never calls connect/logout.

A different existing callback is not replaced implicitly. Only invoking
`M-x whatsapp-repair-incoming` with a prefix and accepting the second warning
permits that replacement; its previous consumer may stop receiving events.
Upstream has no compare-and-swap here, so concurrent external edits remain a risk.
A successful registration is NOT a reachability test from wuzapi to the bridge.
Check the configured callback host/port/network and new incoming counters.
The retained explicit Connect command also preserves subscriptions and no longer
blindly overwrites a different callback. Do not call Connect simply for cosmetics.

## Remaining constraints

Old cached history cannot prove live reception. An HTTP acknowledgement with an
ID proves upstream acceptance, not delivery on the phone. Receipt forwarding must
be supported/enabled by the installed provider. This patch does not restore
expired/deleted upstream files, download unknown original attachments from history
without keys, or infer missing PN/LID mappings. Newly sent media may need a provider
echo/history record with media metadata before it is downloadable in the transcript.

Text work is asynchronous in Emacs; legacy synchronous provider calls still run
in the Guile server. A stuck Guile upstream check can occupy its separate transport
slot. The server buffers request bodies before application limits, so external
ingress needs its own limits. Multimedia decoders are not fully sandboxed.

Native tests, real incoming and outgoing messages, actual account selection,
photo/media permissions, bridge-to-provider compatibility and Pale playback remain
separate acceptance requirements. No real account message was sent by these tests.
Keep the exact printed rollback backup until those checks pass. Never automatically
resend an uncertain message. Current remote HEAD and unknown local edits are not
asserted compatible.

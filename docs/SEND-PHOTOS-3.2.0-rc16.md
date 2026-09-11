# RC16 — recipient acknowledgement and visible photo failures

This is a candidate from the retained RC15 source. The old uploaded reports do not
establish the currently installed or loaded version. Check AUDIT-3.2.0-rc16.md for
executed results. No live WhatsApp recipient, photograph, graphical frame or service
was contacted during preparation.

## What changed

Normal text sends now use authenticated POST /send/verified. It requires an explicit
phone, phone JID, LID, or group JID; a display name or unknown namespace is rejected.
The reply contains recipient_contract=1 and accepted_chat with the bridge's canonical
history key. The worker requires that exact key, preserving @lid and @g.us. A missing
route on an older bridge is an activation error; there is no fallback POST to /send.
Legacy /send is retained for explicit older/media/PQ integrations. The new contract
confirms agreement with this bridge, NOT delivery or a new provider guarantee.

Provider 401/403/400/422 errors have safe local descriptions. Arbitrary provider bodies
are never shown. Drafts remain on uncertainty, late-account results are discarded,
and repeated uncertain sends require deliberate review; previous attempts are not
resent. A provider ID is Accepted, not Delivered. Authenticated matching receipts
remain necessary for Delivered/Read. No cross-namespace receipt matching is added.

Provider history rows with sender_jid="me" and no embedded Info retain own-message
ownership. Explicit Info.IsFromMe=false overrides the fallback. This fixes that
specific historical-data case, not unknown account mapping or arbitrary lost history.

The About endpoint receives full phone JIDs rather than bare phone keys. LIDs remain
unchanged. This is an About-contract correction, not a claim that it repairs every
avatar. For avatars, safe error JSON is now retained even when the worker exits
unsuccessfully. A failed process cannot supply a ready image. Contact info (click the
avatar or C-c i) shows Photo: with a failure category, and Retry photo targets only
that contact without clearing presence consent or other photos. Examples: provider
route missing, provider denial, CDN policy, download, missing FFmpeg, conversion, and
native PNG display. A missing/hidden photo does not mean the contact blocked you.

Photos remain bounded, cached only in memory and subject to privacy. The CDN policy
is NOT widened. This update cannot restore expired media or force another person's
profile photo to be visible. Keep the current provider subscription configuration;
there is no automatic reconnection, privacy change or callback replacement.

Row and hover faces explicitly suppress underline, overline, box, strike-through and
face extension. The current buffer's global hl-line overlay is removed separately
from local hl-line. Unrelated overlays and other buffers are not removed. The cursor
is a bar in WhatsAppel buffers. Layout and source paths are unchanged, and the user's
Home/WhatsAppel/telega init is not replaced. Graphical behavior still requires a native
frame check; no display-driver diagnosis is inferred.

## Guix: update and activate once

Download archive and matching checksum into ~/Downloads. Run in fish, without sudo:

```fish
function whatsappel_update_rc16
    cd "$HOME/Downloads"; or return 1
    sha256sum -c whatsappel-update-3.2.0-rc16.tar.gz.sha256; or return 1
    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc16.XXXXXX"); or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc16.tar.gz -C "$work"; or return 1
    fish "$work/whatsappel-update-3.2.0-rc16/scripts/update-and-activate.fish" \
        "$HOME/whatsappel" --restart-local
end
whatsappel_update_rc16
```

The existing activation wrapper checks the known local user Shepherd service, source,
account, owned listener and lifetime. It runs two full candidate audits, installs only
after success, verifies managed file hashes, and only then restarts the verified
whatsappel-bridge service. If an audit fails, this function does not restart it.
It does not change the Guix profile, .env, pairing, sessions, init or independent PQ
source. Unfamiliar local edits are refused. Do not copy source/ over your live tree.

This update changes client AND bridge. Both must be active for normal text sending.
After success, save work and fully restart Emacs (including a daemon), not just the
client frame. M-x whatsapp-selection-diagnostics must report 3.2.0-rc16. Check delivery
separately: a matched runtime, logged-in provider and registered callback are not
proof that the callback is reachable or a phone received a message. Keep the backup
and use only its printed exact rollback command; newer changes must not be overwritten.

For source-only updating, use scripts/update-guix.fish instead; it does not restart.
For read-only activation preflight, run the activation helper with --check. Do not
restart a guessed service or a remote/tunneled deployment with the local option.

## Live acceptance after native validation

Do not resend old uncertain attempts. Use one deliberately new text with a consenting
recipient. Confirm the selected identity, local Accepted state, matching history
record, authenticated Delivered/Read receipt where available, and actual recipient
confirmation. Capture safe status/error labels, not message text or account tokens.
Inspect Photo: in that contact's details and use Retry photo once. If the CDN policy
rejects a legitimate host, investigate the provider contract instead of disabling
TLS/address protections. Compare navigation in a real frame after restart.

Native tests and fixture routing cannot replace those account-specific checks. Pale
playback remains unfinished from the baseline; no video backend change accompanies
this repair. Existing mpv choice, static images and native GIF scope are retained.
No measured whole-app speedup is claimed.

## Publication is separate

```fish
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
and fish scripts/push-four.fish
```

This retains the isolated RC16 publication checkout, full tests, hidden per-host
credentials, existing four remotes and non-force behavior. No push occurs as part of
updating. Current remote HEAD is not asserted identical to this retained snapshot.

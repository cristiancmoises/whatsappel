# RC13 — exact recipient identity, visible send notes, quiet chat navigation

**Candidate based on the complete retained RC11 release.** RC12 was incomplete
review/diagnostic work, not an installed baseline. This package does not claim that
the operator's live provider, callbacks or recipient phone have been verified.

## Why the previous attempt did not install

The supplied native RC11 report passed 462 Python tests with no skips and every
other gate except ERT. Its failed test was
`wa-rc3-get-uses-worker-post-retains-url-transport`. The fixture retained an old
two-argument worker stub and expected /send to use URL I/O. RC11 intentionally uses
the strict send worker with a payload argument. RC13 retains this test identifier,
checks GET worker routing, checks /send worker payload routing, and independently
checks an unrelated legacy POST still uses its existing URL path. No production
send validation is weakened. Earlier native passes are not RC13 execution evidence.

## Recipient correction

RC11's client kept @g.us but stripped every other @suffix. For example:

```
123456789012345@lid -> 123456789012345       # OLD: different namespace
123456789012345@lid -> 123456789012345@lid   # RC13
```

The inspected upstream provider interprets an identifier without @ as a telephone
recipient. The bridge's history normalizer already preserves @lid. Stripping it
on the client can therefore change the provider destination AND the conversation
under which an accepted outgoing message is stored. This source defect is consistent
with the reported symptoms but is not proof of which live attempt reached whom.

The new client reduces only the two explicit telephone namespaces (@s.whatsapp.net
and @c.us) for old compatibility, preserves groups and opaque qualified targets,
and recomputes normal text targets from the selected JID. Unsupported qualified
names remain for provider validation rather than being coerced to phone numbers.
No PN/LID mapping is inferred. Older stripped destinations are not migrated or
resent automatically. Review old ambiguous attempts with the recipient first.

## What appears when you press Send

Normal text sends create a local status note immediately:

- **Sending:** one request is pending; the current draft is still present.
- **Accepted · awaiting history/receipt:** the strict response includes a provider
  message ID. The unchanged original draft can be cleared; newer edits survive.
- **Unconfirmed:** the outcome is unknown/rejected. The draft remains and there
  is no automatic resend. Inspect the recipient before making a new attempt.

Notes use one owned display overlay, not inserted transcript/draft characters.
They survive empty/stale history snapshots until an accepted provider ID appears
as an own message in the same conversation. Then the actual history record replaces
the local note; Delivered/Read still require existing authenticated receipt handling.
A matching text is insufficient for reconciliation. This is not a durable outbox:
notes are in memory for the lifetime of that chat buffer, limited to 16 entries and
256 KiB combined original text. Each displayed preview is at most 120 columns.

An identical unconfirmed text/target/account is refused until you explicitly review
and dismiss its local note using **Clear local send notes**. That action asks for
confirmation, refuses while sending, and neither deletes nor sends remote messages.
Do not interpret dismissal, HTTP 200, or a local note as recipient delivery.

The new notes concern normal text only. Existing media/PQ paths retain their prior
staging/status behavior while using corrected targets when a chat is opened. No
new attachment encryption, queue persistence or automatic retry is introduced.

## No decorative lines when navigating

`whatsapp-profile-clean-lines` defaults to t. WhatsAppel-local face remaps disable
underline/overline/strike-through/box attributes for contact and button/hover faces.
Local line numbers, fill-column indicators and hl-line highlighting are suppressed.
A subtle background still marks selection. The global theme, other buffers, tab
workspaces and editor preferences remain unchanged. Action rows wrap at their buffer
window width (72-column fallback) instead of growing indefinitely off-screen.

The exact visual cause on the user's frame is not measured here. These changes
remove the app's inherited decorative styles; they do not claim to repair unrelated
GPU/driver rendering corruption. Restart Emacs to load the new definitions. No
blanket deletion of unrelated overlays, re-evaluation of the whole init or global
theme reset is required.

## Existing Guix installation: one guarded update

Download the archive and matching checksum into Downloads. Do not use sudo.
Extract into a fresh directory, retaining previous downloads and backups:

```fish
function whatsappel_update_rc13
    cd "$HOME/Downloads"; or return 1
    sha256sum -c whatsappel-update-3.2.0-rc13.tar.gz.sha256; or return 1
    set -l work (mktemp -d "$HOME/Downloads/whatsappel-rc13.XXXXXX"); or return 1
    tar --no-same-owner -xzf whatsappel-update-3.2.0-rc13.tar.gz -C "$work"; or return 1
    fish "$work/whatsappel-update-3.2.0-rc13/scripts/update-guix.fish" "$HOME/whatsappel"
end
whatsappel_update_rc13
```

The normal update runs two full native audits before replacing managed source.
There is no extra audit-only pair required beforehand. Failures, skips of required
coverage, missing tools and unrecognized local changes stop replacement. The
cumulative manifest includes only explicitly recorded earlier content hashes.
Current remote HEAD and unrecorded variants are not claimed compatible. The complete
source is for reproduction/new installations, not for copying over an active tree.

## Activation and verification

Only AFTER successful installation, restart the known user service:

```fish
herd --log-history=0 status whatsappel-bridge
and herd restart whatsappel-bridge
and herd --log-history=0 status whatsappel-bridge
```

The operator previously verified that this service executes ~/whatsappel/whatsappel.scm.
This command does not select a VPS/container service. It does not reset wuzapi or pair
again. RC13's bridge implementation is RC11 with its version updated, so cumulative
upgrades from RC10 also need the transport module loaded. Save buffers and fully
restart Emacs (including a daemon if used), not just its client frame. Keep your
existing Home/WhatsAppel/telega init setup. Run M-x whatsapp-selection-diagnostics
and confirm the loaded version is 3.2.0-rc13.

Use M-x whatsapp-connection-panel / **Check delivery** to inspect the activated
transport. Provider connected/logged in is distinct from callback correctness,
reachability, and actual recipient delivery. Correcting a recipient suffix does
not automatically repair webhook registration or recover expired media.

After successful native tests and activation, make one explicitly chosen test
message to a contact who agrees to confirm it. Check selected identity, immediate
local note, returned history and recipient receipt. If unconfirmed, do not hammer
Send. Never test by messaging arbitrary contacts or auto-resending previous drafts.
Retain the exact printed rollback backup; rollback refuses subsequent edits.

## Retained scope and publication

Profile loading/presence, mpv, static images/native GIFs and callback tools remain
from RC11. Real Pale playback is still unfinished; this release does not implement
it. Idle is not inferred from silence, and profile data remains privacy-dependent.
No running-user account, outgoing message, restart, pairing change, init edit, Git
push or VPS operation was performed in preparing this distribution.

The existing scripts can prepare/publish a separately audited RC13 worktree:

```fish
fish scripts/commit-and-push.fish "$HOME/whatsappel" --branch main --commit-only
and fish scripts/push-four.fish
```

They retain the four configured repository destinations, hidden token prompts,
clean committed source, no force push, and explicit creation options. Publication
is not automatic installation, and nothing is published by the update command.

Primary reference inspected: wuzapi `parseJID` in wmiau.go (public upstream, not a
claim of the installed build): https://raw.githubusercontent.com/asternic/wuzapi/main/wmiau.go

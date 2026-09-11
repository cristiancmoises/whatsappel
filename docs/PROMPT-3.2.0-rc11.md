# RC11 engineering brief — delivery before decoration

Work from the exact retained RC10 distribution and the separately supplied
messaging-tabs init. Preserve user sessions, account secrets, PQ implementation,
local modifications, original attachments, and the two-pass native installation
gate. Do not run against or send messages to a live account without approval.

Investigate four independent paths: client configuration, provider send
acknowledgements, incoming webhook ingestion/history, and media download/display.
Do not equate a listener health check, cached transcript or HTTP 200 with delivery.
Do not automatically retry a potentially delivered message. Keep drafts when
acceptance is ambiguous. Require a provider message ID before marking accepted;
only matching received receipts can promote accepted to delivered/read.

Verify the primary provider's form, direct JSON and multipart contracts. Parse
binary multipart safely without decoding its attachment as UTF-8, writing a
provider filename, or accepting duplicate jsonData. Preserve ordinary ephemeral
and document-with-caption metadata; never unwrap view-once content. Do not
recreate unknown identities or unread counts from receipts.

Expose a bounded asynchronous, redacted transport check plus a standalone
read-only doctor that works with old bridges. Show provider connection/login,
callback registration, Message subscription, and observed incoming event counts.
An explicit confirmed repair may preserve and merge subscriptions; never silently
replace another callback, reconnect, pair, log out, or change privacy settings.
Explain that callback registration does not prove reachability.

Move ordinary text sends to a bounded owned worker with strict replies, no
redirect/proxy credential forwarding and no automatic resends. Keep media
failures visible and provide explicit conversation-scoped retry. Distinguish
client BRIDGE_URL from reverse-direction provider PUBLIC_URL.

Native images and bounded GIF viewing must not launch mpv by default. Verify
MonadicSheep/Pale's actual source/API before implementing a native video binding.
Never guess functions or call a preference selector a working player. If source
remains inaccessible, disclose the blocker prominently; do not silently launch
mpv. An explicit mpv setting remains usable. Preserve the existing consent,
contact-selection, thumbnail, decryption and account-scope safeguards.

Add real subprocess/loopback HTTP tests, Guile integration tests and ERT coverage.
Run the full audit twice on identical code; missing native runtimes and skips
must remain blocked/partial. Keep baseline/development outcomes. Run package,
patch, update/refusal and rollback checks independently. Deliver full source,
managed cumulative update, prompt, audit, EN/PT-BR instructions, a read-only
first diagnostic command, safe Guix update/activation instructions, and explicit
remaining live/Pale acceptance. No production writes or Git push in preparation.

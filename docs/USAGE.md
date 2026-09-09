# WhatsAppel 3.1 user guide

Open `M-x whatsapp`. The dashboard provides New chat, Search, Refresh and Commands.
Use the All, Unread and Groups filters, click a contact, or press Enter on its row.
Tab visits buttons. `/` searches names, numbers and message previews; `?` opens the
command menu. You can still open a conversation with `M-x whatsapp-open-chat`.

Inside a conversation, type after the prompt. Enter sends; `C-j` adds a newline.
The visible Send and Attach buttons perform the same actions. Drafts, pending
replies and reading positions survive history refresh. `C-c ?` opens Commands.
`C-c C-m` operates on the message at point (reply, react, forward, copy, media,
mark read or deletion). Sensitive message operations still use their existing
confirmation behavior. The optional Org module remains opt-in.

## Attachments and image quality

| Goal | Action | Delivery behavior |
|---|---|---|
| Convenient attachment | Attach… / `M-x whatsapp-chat-attach` | Detects type and offers an appropriate native-media or original-file choice |
| Full-resolution image, RAW image or arbitrary file | Original file… / `M-x whatsapp-chat-attach-original` | Document delivery; no resizing or recompression in this client |
| Supported photo | Attach image | JPEG/PNG native image delivery; WhatsApp may recompress |
| Sticker | Attach sticker | WebP native sticker delivery when supported by wuzapi |
| Video | Attach video | MP4 native delivery; unsupported formats fall back to document |
| GIF-style animation | Attach GIF | MP4 video; stock checked wuzapi has no looping option. A real GIF is sent as a document |
| Office, archive, source code, EPUB, SVG, TIFF, AVIF, HEIC | Attach / Original | Document delivery preserves bytes; native preview is not promised |
| Received media | Enter/open or save on its media line | Explicit retrieval of original downloaded bytes; external player for non-inline formats |

File extensions determine MIME hints, not transcoding or codec compatibility.
Emacs image decoders determine which received image/sticker previews can render.
The scaled preview is independent of the original file. “Original” selects the
WhatsApp document path; local mock tests verify byte preservation through our
bridge, while actual delivery still depends on your wuzapi/WhatsApp deployment.

The default file limit is **16 MiB**. Change both `whatsapp-max-file-bytes` in
Emacs and `WHATSAPPEL_MAX_MEDIA_BYTES` in `.env` if your deployment supports a
larger value. Raise `WHATSAPPEL_MAX_BODY_BYTES` enough for base64 overhead and
JSON (at least approximately four-thirds of the file limit, plus metadata).
Large requests still allocate memory; there is no streaming upload/transcoding.

## Responsiveness

Background polling uses asynchronous HTTP with one refresh in flight per buffer.
Only visible WhatsApp buffers are polled. Unchanged history is not rebuilt.
Automatic image work is limited to recent messages, at most two downloads at a
time, and a byte-bounded in-memory cache. Cache eviction can cause later downloads.
Use `M-x whatsapp-clear-caches` to remove cached media and decrypted previews.

| Setting | Default | Purpose |
|---|---|---|
| `whatsapp-poll-interval` | 5 seconds | Poll cadence when enabled |
| `whatsapp-request-timeout` | 30 seconds | Client request deadline |
| `whatsapp-image-prefetch-count` | 12 recent messages | Limit automatic preview selection |
| `whatsapp-media-cache-max-bytes` | 32 MiB of data URI strings | Bound the media cache |
| `whatsapp-image-max-width` | 400 pixels | Maximum inline photo preview width |
| `whatsapp-sticker-max-width` | 160 pixels | Maximum sticker preview width |

Explicit send/open/save/sync and PQ subprocess operations remain synchronous.
No numerical speedup or constant memory bound for the entire Emacs process is
claimed. The bridge retains bounded chat history and deduplicates message IDs;
wuzapi remains the source for history across bridge restarts.

## Before daily use

Keep the bridge and wuzapi on loopback, retain your current tokens and session,
and test a private conversation with a willing contact: text, reply, one photo,
one original document, download/save and reconnect. Compare original and saved
file hashes for an original-file transfer. The offline audit cannot verify your
WhatsApp account, external media CDN retention, or optional wuzapi retry patch.

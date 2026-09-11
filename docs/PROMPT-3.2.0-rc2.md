# WhatsAppel RC2 engineering prompt

Improve the existing Emacs/Guile WhatsAppel client rather than replace it with a
mock website. Work from the actual rc1 files and keep independently newer source,
Rust code, account configuration, pairing, secrets and concurrent edits intact.
The current user reports slow chat loading and poor interaction compared with
telega. Produce a hash-anchored candidate patch, not an unverified production claim.

## Priorities and execution contract

1. Trace chat-open, list refresh, history serialization, media prefetch, Emacs
   redraw and launcher initialization. Identify blocking work and repeated work
   separately. Do not invent before/after timing measurements. Preserve the old
   HTTP array routes for companion tools and older installations.
2. Implement process-scoped conditional revisions on authenticated read routes.
   Send only a bounded recent history window initially, expand it explicitly,
   and return a small unchanged envelope on idle polls. Cache sorted summaries
   until a mutation invalidates them. Keep serialization outside the store lock.
   Preserve unread behavior for legacy callers, and give diagnostic v2 reads a
   strictly non-marking read=0 mode. Validate revision and window metadata.
3. Keep slow automatic media downloads out of the bridge's serial accept loop.
   Use at most two worker/result slots, authenticated polling and bounded
   retention. Never route sends through a retried job. Preserve CDN/metadata,
   size and authentication validation. An expired download is not a delivered
   message; a busy or failed result requires explicit retry. Do not introduce
   public access, new listening ports or a browser dashboard.
4. Display cached chat content before network work. Render compact, width-aware
   conversation rows, initially bounded to 80, with full-cache search, filters,
   unread badges, keyboard navigation, click-to-open and More. Preserve existing
   Forward, reply, attachment and Org bindings. Offer contextual message actions
   without repeating a large button on every message.
5. Update only changed history tails or sliding-window additions when possible.
   Leave the draft marker, draft characters and draft undo history alone. Keep a
   full-render fallback for layout/window changes. Update image display properties
   without erasing conversation text. Keep media jobs pinned to their originating
   account and buffer, and discard late replies after account changes.
6. Provide an optional Emacs -Q quick launcher without silently losing settings
   stored only in the user's init. Add a read-only HTTP doctor that reports
   timing, payload sizes and counts but never records tokens, chat identifiers,
   names, messages or response bodies. Refuse redirects and non-loopback HTTP;
   disable inherited proxies. Do not probe legacy /chat because it marks read.
7. Add native ERT regressions for conditional reads, stale callbacks, bounded
   rendering, search beyond the first page, draft preservation, sliding updates,
   image display-only changes and job routing. Add real Guile HTTP tests against
   a deterministic loopback backend, including slow-media isolation and worker
   saturation. Test the Python doctor with real HTTP and the quick launcher with
   process arguments inspected. Static Lisp checks are not a compiler or ERT.
8. Run the complete available audit twice from the same source. Record PASS,
   FAIL, BLOCKED and skipped tests accurately. Include client byte compilation,
   ERT, layout benchmark, Guile unit/HTTP tests, fish syntax, media tool checks,
   Python regressions and unchanged Rust tests/format/Clippy. Missing tools must
   result in an unsuccessful overall gate, not a reduced passing audit.
9. Package full changed files, a Git patch, checksums, English/PT-BR usage,
   limitations and raw evidence. Verify patch forward/reverse round trips and
   installation refusal on missing native tools. Use two native audit passes
   before source installation; preserve private rollback backups. Clearly state
   that bridge source changes require restarting its existing launcher, and that
   a successful build is not proof of actual WhatsApp delivery.

## Release acceptance

Do not call this stable or production-validated until native suites pass and a
human has exercised GUI chat switching, draft preservation, image decoding,
mpv playback, microphone recording, explicit sends and actual recipient receipt.
No synthetic benchmark proves end-to-end speed. Keep blocked gates visible.
Do not publish, deploy, replace unrelated containers, or bypass a declined remote
permission request. Report any repository side effects that actually occurred.

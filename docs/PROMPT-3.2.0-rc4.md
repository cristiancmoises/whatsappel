# WhatsAppel RC4 — executed engineering prompt

Act as the maintainer of a native Emacs/Guile WhatsApp client. Continue from the
retained 3.2.0-rc3 source and evidence, not a fabricated current remote checkout.
The user wants faster chat loading and a more usable telega-like interface.
Deliver an implemented, measured, reversible update rather than a redesign brief.

## Boundaries

Preserve the existing architecture, GPL-family notices, configuration, pairing,
session files, independently newer pqenv code, original media, and draft contents.
Do not expose ports, change NPM, touch wuzapi, force-push, create branches, retry a
previously declined CI write, or send a real WhatsApp message. Keep native voice/GIF
and cryptography limitations explicit. Prefer small, auditable changes over a new
framework or unsupported multi-account claims.

## Investigate and implement

1. Inspect actual chat-read parsing and list rendering. Distinguish CPU work,
   subprocess startup, network latency, bridge latency, and native Emacs display.
   Measure the operation changed; never label an isolated parser speedup as an
   end-to-end WhatsApp improvement.
2. Optimize the bounded JSON depth prepass without removing its nesting limit,
   duplicate-key rejection, response-byte cap, total deadline, redirect refusal,
   proxy avoidance, strict UTF-8 parsing, or secret redaction. Exercise ordinary
   chat summaries, large text, media-like base64, and hostile escape density.
   Reject exponent overflow as well as literal NaN/Infinity. Keep a measured
   fallback when a fast path is slower on dense escapes.
3. Treat unread totals as content, not layout. When ordering/filter membership
   stays unchanged, update only the summary line and affected visible rows.
   Changes outside the page must not rebuild visible rows. Retain safe bounded
   full rendering for genuine structural changes.
4. Add a cache-only conversation switcher with standard Emacs completion,
   unambiguous contact identity, bounded annotations, cancel safety, and access to
   every cached chat, not just the current page. Do not add a synchronous lookup.
5. Add a mouse-accessible compact/detailed list toggle and a non-group filter.
   Preserve the active filter, query, page limit, selection, and existing forward
   keybinding. Keep density buffer-local; do not introduce silent disk persistence.
6. Correct any release identity mismatch found in the client and publication helper.

## Evidence and release gate

Write seeded differential parser tests, exact depth/escape boundary tests, strict
number/query tests, real read-worker subprocess/HTTP tests, and focused ERT cases
for the UI. Run the entire existing audit twice against identical source hashes.
Use PASS/FAIL/BLOCKED accurately: a Python structural scanner is not an Emacs reader
or runtime, a subprocess fixture is not a recipient-delivery test, and benchmark
output equivalence is not a timing SLA. Preserve interrupted/failed attempts.

Package a cumulative content-anchored update from the retained 3.1/RC1/RC2/RC3
baselines; no approximate patch matching. Verify payload digests, standalone
RC3-to-RC4 patch application and reversal, all supported baseline preflights,
newer-edit rejection, configuration/PQ preservation, rollback, final archive
checksums, and the actual fail-closed installer. Only mocks used to isolate file
transactions may replace native gates in test fixtures, never in the installer.

Deliver the executed prompt, actual code, EN/PT-BR usage and audit notes, raw test
logs, before/after benchmark samples, patch, archive/checksum, and fish-safe local
validation/install commands. Native and live gaps keep the release candidate
label. No guarantees that everything works without the corresponding evidence.

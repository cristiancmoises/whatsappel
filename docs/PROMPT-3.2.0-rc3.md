# WhatsAppel RC3 engineering prompt

Continue the existing WhatsAppel project from the retained RC2 source, not a new
mock application. Focus on predictable chat loading, telega-inspired native Emacs
interaction, and honest validation. Preserve AGPL notices, Guile/wuzapi contracts,
Org integrations, user drafts, configuration, account sessions and independent PQ
changes. Do not rewrite the cryptography or introduce an unrelated web frontend.

## Investigate and implement

Inspect actual request and render paths before proposing a fix. Reduce work on
the interactive Emacs thread, enforce bounded response handling and a total child
read deadline, and keep a working cache visible when reads fail. Read credentials
only from existing protected configuration; never place secrets in command lines,
URLs, test reports or persistent helper files. Do not follow redirects, inherit
proxy routes or automatically retry sends. Parse JSON without interning remote
keys; validate record identities and render fields before replacing snapshots.

Replace changed conversation rows in place when ordering and layout permit it.
Keep bounded full rendering for structural changes. Preserve draft markers and
scroll position rather than hiding the cost with animation. Start polling from
normal launch/open commands, but respect the user's explicit pause. Polling a
background conversation must not mark it read on the v2 bridge. Acknowledge only
a demonstrably focused conversation, retaining an explicit manual action.

Download only image previews intersecting visible conversation windows; debounce
scroll-driven work and discard hidden queued prefetch. An explicit media click
must share an already queued request and open when ready without a second click.
Stale callbacks must not steal focus, clear newer drafts or cross account scopes.
Stop owned read processes when their buffers die. Keep mpv, original media bytes,
and explicit recording/attachment confirmation workflows.

## Tests and delivery

Add real local HTTP/subprocess tests for status handling, bad JSON, body framing,
limits, slow-drip deadlines, redirects, proxy isolation and secret redaction. Add
native ERT for incremental rows, focus/read behavior, loading/empty states,
viewport prefetch, click coalescing and worker integration. Run the available
regression suite and full audit twice against identical source fingerprints.
Missing Emacs, Guile, fish, mpv or Rust are BLOCKED, not PASS. Do not substitute a
Python delimiter scanner for native Lisp compilation or claim live message
receipt, UI screenshots, speedup percentages, deployment or remote publication.

Build a cumulative managed bundle accepting only exact per-file anchors from the
retained 3.1, RC1 and RC2 snapshots plus the delivered candidate. Preserve unknown
edits by refusing them. Verify each supported baseline, patch apply/reverse,
rollback, independent PQ/config preservation and actual missing-runtime refusal.
Ship the prompt, changed source, tests, audit evidence, English/pt-BR usage,
checksums and fish entrypoints. Keep the installed source untouched until both
native changed-code gate passes succeed. Do not retry the previously declined
GitHub workflow write or perform new remote writes.

Report what was implemented, what actually ran, what failed/was blocked, and exact
local commands. Keep the release candidate label until native and live acceptance
is complete. The next iteration must start from this candidate and its evidence.

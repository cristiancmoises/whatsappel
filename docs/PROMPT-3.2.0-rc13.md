# RC13 engineering prompt — correct recipients before cosmetic work

Work from the exact retained RC11 release and the operator's uploaded full audit.
This is a focused repair, not a promise that a live WhatsApp session works. Preserve
unknown local edits, account configuration, pairing, provider sessions and PQ keys.
Do not substitute the incomplete RC12 review tree for the verified baseline.

## Evidence and required diagnosis

1. Compare the operator report's code fingerprints with the baseline. Distinguish
   a candidate being tested from installed files and loaded Emacs/bridge processes.
2. Investigate the sole failed ERT `wa-rc3-get-uses-worker-post-retains-url-transport`.
   Compare the current strict /send worker contract with the test's stub/signature.
   Preserve the test identifier; correct the obsolete fixture without routing sends
   back through weaker transport or skipping any assertion.
3. Trace the selected chat JID through the Emacs target conversion, JSON worker,
   Guile handler, provider Phone argument, history key and receipt lookup. A LID is
   not a telephone number: never remove @lid or match it to a phone by shared digits.
   Preserve group identities and legacy known phone suffix compatibility.

## Repair contract

Opening, composing and sending must use the full selected identity. Recompute the
normal text target from the actual chat JID rather than a cached legacy target.
Never resend old attempts, move previous records between namespaces, infer identity
mappings, delete history, reset sessions, or reconnect to hide failures.

Show a bounded in-memory local send note immediately when the user explicitly sends
normal text. Distinguish Sending, Accepted awaiting history/receipt, and Unconfirmed.
Provider acceptance is not delivery. Reconcile accepted notes only by provider ID
and own-message flag from the same account/conversation's authoritative snapshot.
Never deduplicate by matching text alone or invent a wire message ID.

Keep newer edits and unknown-outcome drafts. Guard duplicate pending callbacks,
account changes, closed buffers, memory limits and accidental repeat of an uncertain
draft. Dismissal must be explicit and must never send or delete anything remotely.
Local status must not modify transcript characters, draft markers or undo positions.
Use a single owned overlay, not accumulating overlays on every redisplay.

Remove inherited underlines, overlines, boxes, strike-through and editor line guides
in WhatsAppel buffers only. Keep clear background selection and hover; preserve the
user's global theme, Centaur/tab-bar setup, unrelated buffers and line-number choices.
Do not use blanket delete-all-overlays or full root rewrites when moving selection.
Wrap overlong action rows at their actual window width without losing command identity.

## Verification

Retain every previous test. Add ERT for LID/phone/group targets, stale cached target,
accepted and unknown outcomes, ID-based reconciliation, draft/undo/point preservation,
duplicate callbacks, changed credentials, bounded notes, explicit clearing and many
selection/hover updates. Test local face remapping and toolbar command identity.

Use real Python worker subprocesses with local HTTP fixtures for exact qualified
recipient arguments and a single POST per explicit attempt. Add native Guile tests
that verify LID storage and matching receipts remain separate from equal phone digits.
A mocked opener, parser model or structural scanner is not a native Emacs result.

Run the full audit twice on identical code. Preserve interrupted/development attempts
separately. Count skipped/blocked tests explicitly. Do not claim recipient delivery,
GUI correctness, performance percentages or Pale playback from offline passes.

## Deliver

Produce a uniquely named complete RC13 archive, cumulative content-anchored payload,
review patch, checksums, EN/PT-BR guide, diagnosis and execution evidence. Test direct
RC10/RC11 updates, rollback, unchanged sensitive/unmanaged files, altered-file refusal,
patch round trip, and delivered-code equality to both audit fingerprints.
Keep the exact-candidate two-pass native gate with no bypass. Give one fish update
command followed by explicit activation of the already identified local service only
when installation succeeds. Do not edit init, run guix pull, push, or change services
in this preparation. Pale integration and optional RC12 profile work remain separate.

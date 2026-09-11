# RC16 execution brief — recipient identity, photos, and contact-row artifacts

Use the exact complete RC15 distribution as the baseline. Treat the provided runtime
and candidate reports as historical evidence, not proof that RC15 is installed.

Trace normal text from selected JID through the client worker, authenticated bridge,
provider Phone field, own-history merge, and receipt path. Do not infer a telephone
number from a LID. Keep legacy APIs compatible, but require new normal text sends to
receive a versioned, exact recipient-key acknowledgement; no fallback POST on an old
bridge and no automatic resend on any ambiguity. Provider message IDs prove acceptance
only. Preserve drafts and late-account guards. Do not claim live recipient delivery
from fixture HTTP or a local accepted note. Validate explicit recipient identifiers
before provider requests; retain safe classified rejection errors without raw bodies.

Inspect empty data_json history rows and preserve the explicit own sender marker.
An explicit false IsFromMe must win over that fallback; do not infer ownership from
message text. Extend native bridge tests without weakening previous tests.

Trace profile success and error results through process exit, worker JSON, caches,
and image decoding. Nonzero workers may report a safe error category but must never
publish a ready photo. Add per-contact Retry photo and a bounded readable failure
label. Preserve consent, other accounts, byte/pixel/time bounds, HTTPS verification,
DNS pinning and the verified CDN host policy. Do not interpret private/unavailable
photos as blocked contacts or relax networking policies for appearance. Correct the
About API phone-JID contract without guessing PN/LID mapping.

Remove decorative lines from actual row and hover faces with explicit attributes.
Disable local guides and remove only a global hl-line overlay owned by the current
WhatsAppel buffer. Preserve unrelated overlays, editor buffers, draft positions,
text and global theme. Test repeated selections and actual overlay ownership. A
terminal/batch test cannot claim a graphical screenshot or a repaired GPU artifact.

Execute the baseline suite, targeted subprocess/HTTP/FFmpeg tests, and the full audit
twice against frozen final source. Retain development failures. Missing native tools
stay BLOCKED. Write new ERT/Guile tests, register them, and report unexecuted tests
separately. Keep source-anchored transactional installation, two native passes,
private backup and rollback checks. Provide a complete cumulative package, review
patch, EN/PT-BR instructions, evidence, and a fish workflow that cannot restart on
failed installation. No service access, messages, callbacks, pairing, or remote writes
are performed during preparation. Keep Pale explicitly unfinished; do not select or
install another native backend as a side effect.

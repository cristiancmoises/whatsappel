# RC15 engineering brief — preserve send truth, prove activation stages

Continue from the complete verified RC14 archive, not the stale uploaded RC11 audit
or the incomplete RC12 work. Preserve the original late-account callback regression
and every validation guard. Inspect the source rather than claiming phone delivery.

1. Trace the accepted send callback. Isolate an exception starting history refresh
   from send acceptance. Keep the validated accepted note, newer draft, account scope,
   duplicate-callback protection, provider-ID requirement and no-resend policy.
   Add native tests for refresh failure, changed drafts, stale accounts and negative
   acknowledgement. Do not remove old assertions or silently retry messages.
2. Add a source-install/activation workflow rather than unguarded shell restarts.
   Default does not restart; explicit --restart-local supports only the already known
   local user Shepherd service. Validate source UID/argv, token/port in memory, socket
   ownership and process lifetime. Reject unknown deployments instead of guessing.
3. Reuse the exact-candidate two-full-audit installer without a bypass. Verify every
   installed managed payload and recheck account/service identity before restart.
   Invoke restart once, require a new matched process, then independently probe the
   live transport/version. A healthy HTTP response or successful herd exit is not
   sufficient. A failed install must never reach restart.
4. Provide a private stage report: preflight, installing/auditing, disk mismatch,
   restart, installed-but-inactive, verified runtime. Separate provider registration
   from runtime success and actual recipient delivery. No raw environment, provider
   responses, personal messages or tokens in summaries. Read-only mode must not
   install, restart, send, repair callbacks or reset sessions.
5. Execute real Python filesystem, child-process, loopback HTTP and /proc socket tests.
   Label simulated Guile process metadata and mocked service/updater sequences. They
   test safety order, not native application correctness. Run full audits twice on
   final frozen code; keep failures and native blocks visible. No relabelling skipped
   tests as passes. Preserve failed development evidence and fix real fixture errors.
6. Ship a new RC15 complete/cumulative package, review patch, EN/PT-BR instructions,
   checksums and evidence. Preserve recorded compatibility anchors, newer PQ code,
   .env, sessions, init and rollback guards. No remote publication or user service
   changes during development. Keep Pale's unfinished status explicit. Do not invent
   speedup numbers, presence states, native tests or working screenshots.

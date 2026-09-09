# pqenv — post-quantum message envelope

A small Rust CLI/library that seals a message so only a chosen recipient can read
it and only a chosen sender could have written it, using post-quantum primitives.
Built for whatsappel: the envelope rides inside a WhatsApp text message as an
opaque `WAPQ1:` blob. It is **not** "post-quantum WhatsApp" — see the threat model.

## Suite (0x02)

| Role | Primitive | Standard |
|---|---|---|
| KEM | ML-KEM-1024 (implicit rejection) | FIPS 203 |
| KDF | HKDF-SHA256, domain-separated | RFC 5869 |
| AEAD | ChaCha20-Poly1305 | RFC 8439 |
| Signature | ML-DSA-87 (context = domain string) | FIPS 204 |
| Freshness | authenticated `ts` + random `msg_id` (signed + in AAD) | — |

Suite `0x02` adds an authenticated metadata block (an 8-byte Unix timestamp and a
16-byte random message id) to every envelope, enabling freshness-window and replay
checks at open time. The metadata is covered by both the signature and the AEAD
AAD, so it cannot be altered without rejection.

Primitives are [libcrux](https://github.com/cryspen/libcrux) (`libcrux-ml-kem`,
`libcrux-ml-dsa`, currently 0.0.10). Upstream verification applies to specific
implementations and proof assumptions; it does not verify this protocol, its CLI,
or every dependency/backend. This crate composes existing primitives and forbids
unsafe Rust in its own source. Explicit secret buffers use `Zeroizing`; that does
not guarantee erasure of compiler copies, upstream key objects, swap or backups.
Randomness comes from the OS CSPRNG via `getrandom`. Commit Cargo.lock and re-audit
on dependency changes.

## Identity

Each user has two key pairs: an ML-KEM pair (others encapsulate to your public
key to send to you) and an ML-DSA pair (you sign what you send). `keygen` writes
`NAME.public` (shareable) and `NAME.secret` (mode 0600). Existing keys are
refused, including when only one member of a pair exists. Choose a new identity
prefix to rotate keys; verify the new fingerprint with contacts.

## CLI

```
pqenv keygen --out alice
pqenv keygen --out bob

# alice -> bob, signed by alice
echo "olá Bob" | pqenv seal --recipient bob.public --identity alice.secret > ct.txt

# bob reads it, verifying it came from alice
pqenv open --identity bob.secret --sender alice.public --in ct.txt

# reject messages older/newer than 1h, and reject replays (duplicate msg_id)
pqenv open --identity bob.secret --sender alice.public --in ct.txt \
           --max-age 3600 --seen bob.seen

# verify a contact's key out of band
pqenv fingerprint alice.public
```

`seal`/`open` read stdin or `--in`, write stdout or `--out`. `open` verifies the
signature **before** decapsulating or decrypting. `--max-age SECONDS` rejects an
envelope whose timestamp is outside the window (`abs(now - ts) > max_age`);
`--seen FILE` rejects an envelope whose `msg_id` already appears in FILE (and
otherwise records it, pruning entries older than `--max-age`). Either rejection
exits with status **3**, distinct from other failures (exit 1).

## Build

```
cargo build --release --locked       # binary at target/release/pqenv
cargo test --locked         # RFC 5869 + RFC 8439 vectors and composition tests
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Rust ≥ 1.89 is required for standard-library OS file locks. This revision was
tested with Rust 1.93.0 on x86_64 Linux; the minimum toolchain and other
architectures were not exercised in this review.

## Wire format

```
WAPQ1:<base64(binary)>

binary:
  magic[6]                 "WAPQ1\0"
  suite[1]                 0x02
  u16 len, kem_ct[len]     ML-KEM-1024 ciphertext (1568 bytes)
  u16 len, meta[len]       ts[8 BE seconds] || msg_id[16 random]   (24 bytes)
  u32 len, aead_ct[len]    ChaCha20-Poly1305(plaintext);
                           AAD = magic || suite || kem_ct || meta
  u16 len, sig[len]        ML-DSA-87 over (magic .. end of aead_ct); context = DOMAIN

KDF:    HKDF-SHA256(ikm = ML-KEM shared secret, salt = none, info = DOMAIN)
        -> 32-byte key || 12-byte nonce
DOMAIN: "WAPQ1 ml-kem-1024+ml-dsa-87+chacha20poly1305+hkdf-sha256 v1"
```

The 12-byte nonce is derived from the per-message shared secret, which is fresh
for every encapsulation, so the (key, nonce) pair never repeats. `meta` is
authenticated by both the signature and the AEAD AAD; `ts`/`msg_id` are visible in
the blob (they add no metadata beyond what the transport already sees) and exist
only to support freshness and replay checks.

## Threat model

**Protects (between two parties who hold each other's public keys):**
- Confidentiality of message content against any party without the recipient's
  ML-KEM secret, including a quantum adversary and "harvest-now-decrypt-later"
  capture of the carried ciphertext.
- Integrity and sender authentication: a valid envelope could only have been
  produced by the holder of the sender's ML-DSA signing key, and any bit flip is
  rejected.

**Does NOT protect against:**
- Non-participants gaining anything: to anyone not running pqenv with exchanged
  keys, the payload is an opaque blob — this adds nothing to normal WhatsApp
  contacts.
- Metadata exposure: sender, recipient, timing, size, and group membership remain
  visible to the transport (WhatsApp/Meta). This is content encryption, not a
  metadata-private channel.
- Endpoint compromise: plaintext exists before `seal` and after `open` on each
  host; a compromised device defeats it.
- Key-distribution attacks: public keys are exchanged out of band. Verify
  fingerprints over a trusted channel; absent that, it is trust-on-first-use.
  There is no PKI, no revocation, no expiry.
- Replay, partially: suite `0x02` carries an authenticated timestamp and random
  message id. `open --max-age` rejects envelopes outside a freshness window
  (defeating replay of *old* captured envelopes), and `open --seen FILE` rejects a
  `msg_id` seen before. Caveats: the seen-store is per-device and grows until
  pruned by `--max-age`; freshness assumes loosely synchronised clocks; and replay
  of a *recent* envelope within the window is only blocked when a `--seen` store is
  used. A receiver that re-processes the same envelope (e.g. re-rendering history)
  must therefore gate the `--seen` check on a first-sight/accept event, not on
  every read — the whatsappel client uses the freshness window on view for this
  reason. Per-message replay-on-receive accept-state is not yet built.
- Forward secrecy: the `seal`/`open` envelope uses long-term KEM identity keys,
  so compromise of a recipient's ML-KEM secret decrypts previously captured
  envelopes addressed to them. For forward secrecy, use the WAPQR session layer
  below instead of the single-shot envelope.

## Forward-secure sessions (WAPQR v1)

A stateful, opt-in session layer that adds forward secrecy. Primitives are the
same (ML-KEM-1024, ML-DSA-87, ChaCha20-Poly1305, HKDF-SHA256).

Custom handshake (one signed one-time prekey; **not Signal PQXDH**):

```
# responder publishes a one-time prekey, signed by its long-term identity
pqenv ratchet-prekey --identity bob.secret --out bpre
#   -> bpre.prekey (give to alice, once)   bpre.prekey.secret (0600, one-time)

# initiator verifies the prekey, encapsulates, signs an init token
pqenv ratchet-init --identity alice.secret --peer bob.public \
      --prekey bpre.prekey --session alice.session --out init.tok

# responder verifies the init token, decapsulates, and CONSUMES the prekey secret
pqenv ratchet-accept --peer alice.public --prekey-secret bpre.prekey.secret \
      --init init.tok --session bob.session     # deletes bpre.prekey.secret

# thereafter, per message (session files advance in place, 0600):
echo "hi" | pqenv ratchet-send --session alice.session --out m1
pqenv ratchet-recv --session bob.session --in m1            # -> "hi"
```

How forward secrecy is obtained: the session seed comes from encapsulating to the
responder's *ephemeral* prekey, whose secret is deleted at `ratchet-accept`. After
that, neither party's long-term secret can recover the seed. The seed feeds a
symmetric hash ratchet — `(ck', mk) = HKDF(ck)` — where each message key is used
once and dropped and the previous chain key is overwritten, so a later compromise
of a chain key cannot derive earlier message keys. A bounded look-ahead cache
(≤512 keys) tolerates out-of-order and lost messages; `ratchet-recv` exits 3 on
replay, on counters too far ahead, on wrong-session/wrong-direction headers, and
on any AEAD failure, without mutating session state.

Authentication is established once at the handshake: the prekey is signed by the
responder and the init token by the initiator (distinct ML-DSA contexts). Both
signatures are verified before any key is derived; a prekey or init token signed by
the wrong identity is refused. Per-message authenticity follows from the AEAD,
since only the two peers hold the ratchet keys.

**Does NOT protect against (WAPQR-specific):**
- Post-compromise security: there is a single ephemeral bootstrap and no continuous
  asymmetric ratchet, so a leaked chain key exposes every later message in that
  session until a new session is bootstrapped.
- State loss or rollback: the session files hold the live chain keys; restoring an
  old copy reuses keys. Treat them as live key material (0600).
- Metadata and endpoint exposure: unchanged from the envelope above.
- Group messaging: 1:1 only; no group keying.

## State and file handling

Put identities, session files and replay databases in a directory owned by you
with mode 0700 on a local filesystem. Stateful commands use persistent `.lock`
files and OS advisory locks. A busy operation fails instead of processing the
same chain key twice; retry after the other operation completes. Do not delete
lock files while any process may use them, and do not mix this revision with an
older binary that ignores locks. Symlinked or multiply hardlinked state is
refused. Directory control and backup rollback remain outside this protection.

Updates use mode-0600 random temporary files, file `fsync`, atomic rename and
parent-directory `fsync`. An existing ordinary `--out` file can be atomically
replaced, including Emacs-created temporaries; `--out` cannot name a key/session/
replay file passed to the same command. Newly created identities, prekeys and
sessions refuse overwrite. Output redirection (`> file`) is controlled by your
shell and its umask, so use `umask 077` for private plaintext.

`ratchet-accept` durably writes a `.prekey.secret.consumed` marker before saving
its session and deleting the prekey secret. Keep that marker: it blocks accidental
reuse after a crash even if the old secret remains. If acceptance fails after the
marker was written, generate a fresh prekey and start a new handshake. Deleting a
secret file does not securely erase SSD, journal, snapshot or backup copies.

Session advancement is persisted before ciphertext/plaintext output. A later
output failure may lose that message; restoring older state to retry risks key
reuse. The CLI is not a transactional network transport. Corrupted/unreadable
replay stores and malformed freshness options fail closed. Replay stores require
application-level retention and remain device-local.

The CLI reads at most 32 MiB per input. Envelope plaintext is limited to 24 MiB
minus 8 KiB to leave room for headers and base64; ratchet plaintext is limited to
32 MiB minus 64 bytes. WhatsApp text transport imposes much smaller practical
limits. These limits do not apply to the bridge's normal attachment uploads.

## Security testing and audit

Test surface (`cargo test --locked`, 39 tests on 2026-09-09):
- Known-answer vectors: HKDF-SHA256 (RFC 5869), ChaCha20-Poly1305 tag (RFC 8439).
- Envelope: roundtrip, tamper rejection, wrong-sender / wrong-recipient rejection,
  freshness metadata presence/uniqueness.
- Ratchet: chain mirroring, in-order stream, out-of-order within window, replay,
  skipped-then-replayed, too-far-ahead, tamper, reflection, wrong-session, forged
  prekey, forged init, forward-secrecy key disposal, session (de)serialization.
- Property-based (proptest): `open`, `Session::from_bytes`, `accept`, and ratchet
  `decrypt` never panic on arbitrary bytes (DoS surface); envelope roundtrip over
  arbitrary plaintext; single-bit-flip never yields a different plaintext; and an
  in-order message stream delivered in an arbitrary permutation decrypts exactly
  once per message.

Additional regression coverage checks strict binary parsing, counter overflow
without mutation, duplicate skipped keys, process locking, mode-0600 atomic
replacement, symlink/hardlink rejection, identity overwrite refusal, malformed
freshness flags, corrupted replay databases, and consumed-prekey recovery.

Dependency audit on **2026-09-09** (`cargo audit`, database commit
`d502590ca247f3e53b56bf6c2ae40b61926800e5`): **0 vulnerability advisories**, with
**1 maintenance warning** for transitive `proc-macro-error2` 2.0.1
([RUSTSEC-2026-0173](https://rustsec.org/advisories/RUSTSEC-2026-0173.html)).
The original lockfile reported three vulnerability advisories; this revision
updates libcrux ML-KEM/ML-DSA to 0.0.10, SHA3 to 0.0.10 and secrets to 0.0.6.
`anyhow` moves to 1.0.104 to resolve its unsoundness warning; the yanked transitive
`chacha20` 0.10.0 is replaced by 0.10.2. The independent RustCrypto AEAD still uses
its compatible `chacha20` 0.9.1 dependency. A database scan does not establish the
absence of unknown vulnerabilities. See [the dated audit](AUDIT-2026-09-09.md).

This review exercised the default x86_64 build and inspected the composition
source. It did not prove constant-time behavior, rerun upstream formal proofs,
perform an independent cryptographic protocol review, run Miri/sanitizers, or test
AArch64/SIMD backends. No security certification is claimed.

## License

`AGPL-3.0-only` (SPDX headers in every source file). Dependencies: libcrux is
Apache-2.0; RustCrypto crates (chacha20poly1305, hkdf, sha2) are MIT/Apache-2.0.

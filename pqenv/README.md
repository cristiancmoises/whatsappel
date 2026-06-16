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
`libcrux-ml-dsa`), whose field/NTT/serialization code is formally verified with
hax and F*. This crate only *composes* them; it reimplements no primitive. The
crate root is `#![forbid(unsafe_code)]`; key material is held in `Zeroizing`
buffers; all randomness comes from the OS CSPRNG via `getrandom`. libcrux is
pre-1.0 — pin the version and re-audit on bumps.

## Identity

Each user has two key pairs: an ML-KEM pair (others encapsulate to your public
key to send to you) and an ML-DSA pair (you sign what you send). `keygen` writes
`NAME.public` (shareable) and `NAME.secret` (mode 0600).

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
cargo build --release       # binary at target/release/pqenv
cargo test                  # RFC 5869 + RFC 8439 vectors and composition tests
cargo clippy -- -D warnings
cargo fmt --check
```

Rust ≥ 1.78 (libcrux MSRV). Tested on stable 1.96.

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

Handshake (PQXDH-style, one signed one-time prekey):

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

## Security testing and audit

Test surface (`cargo test`, 27 tests):
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

Dependency advisory audit: the resolved tree (release and dev) was checked against
the RustSec advisory database by version range. Result: zero unpatched advisories.
The recent libcrux ML-DSA verification advisories — RUSTSEC-2026-0076 (hint-decode
out-of-bounds panic) and 2026-0077 (signer-response norm check), patched in 0.0.8,
and 2026-0125 (AVX2 `use_hint` edge case), patched in 0.0.9 — are the reason the
ML-KEM/ML-DSA pins are `0.0.9`. Re-run advisory checks on every dependency bump.

Constant-time and memory posture: secret comparisons and branches are delegated to
vetted constant-time code — AEAD tag verification (RustCrypto `subtle`), ML-KEM
implicit-rejection decapsulation and ML-DSA verification (libcrux). This layer adds
no secret-dependent branch or index; the only direct comparison is on the public
session id. All key material — identity secrets, KEM shared secrets, root/chain/
message keys, and serialized session state — is held in `zeroize::Zeroizing`.

Formal verification scope: the primitives carry machine-checked proofs upstream
(libcrux, via hax/F*). The composition layer here is plain safe Rust
(`#![forbid(unsafe_code)]`), so the C/assembly-oriented tooling (Jasmin `jasmin-ct`,
Frama-C/ACSL, EasyCrypt) does not apply to it and was not run; assurance for this
layer comes from the KAT, property, and advisory checks above, not from an
independent formal proof or third-party audit.

## License

`AGPL-3.0-only` (SPDX headers in every source file). Dependencies: libcrux is
Apache-2.0; RustCrypto crates (chacha20poly1305, hkdf, sha2) are MIT/Apache-2.0.

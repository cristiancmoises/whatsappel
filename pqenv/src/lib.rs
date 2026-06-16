// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
//
//! Post-quantum message envelope for whatsappel.
//!
//! Suite 0x01: ML-KEM-1024 (FIPS 203) -> HKDF-SHA256 (RFC 5869, domain-separated)
//! -> ChaCha20-Poly1305 (RFC 8439); ML-DSA-87 (FIPS 204) signature over the header.
//!
//! Primitives are libcrux (formally verified with hax/F*); this crate only
//! composes them. It does NOT reimplement any primitive.
//!
//! Scope: this protects message *content* between two parties who both run
//! whatsappel and have exchanged public keys. To anyone else it is an opaque
//! blob. It does not hide metadata (sender, recipient, timing) from the
//! transport. See the threat model in README.

#![forbid(unsafe_code)]

use std::error::Error;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use libcrux_ml_dsa::ml_dsa_87::{
    self, MLDSA87Signature, MLDSA87SigningKey, MLDSA87VerificationKey,
};
use libcrux_ml_kem::mlkem1024::{
    self, MlKem1024Ciphertext, MlKem1024PrivateKey, MlKem1024PublicKey,
};

pub mod ratchet;

#[cfg(test)]
mod proptests;

pub type Result<T> = std::result::Result<T, Box<dyn Error>>;

/// Transport tag prepended to the base64 blob so the bridge can recognise it
/// inside a WhatsApp text message.
pub const TRANSPORT_PREFIX: &str = "WAPQ1:";

const MAGIC: &[u8; 6] = b"WAPQ1\0";
const SUITE: u8 = 0x02; // v2: adds an authenticated ts + msg_id (freshness/replay)
const META_LEN: usize = 24; // ts(8 BE seconds) || msg_id(16 random)
/// Domain-separation string for both HKDF `info` and the ML-DSA context.
const DOMAIN: &[u8] = b"WAPQ1 ml-kem-1024+ml-dsa-87+chacha20poly1305+hkdf-sha256 v1";

// FIPS-fixed serialized sizes.
const KEM_PK: usize = 1568; // ML-KEM-1024 encapsulation key
const KEM_SK: usize = 3168; // ML-KEM-1024 decapsulation key
const KEM_CT: usize = 1568; // ML-KEM-1024 ciphertext
const SIG_PK: usize = 2592; // ML-DSA-87 verification key
const SIG_SK: usize = 4896; // ML-DSA-87 signing key
const SIG_LEN: usize = 4627; // ML-DSA-87 signature

pub(crate) fn boxed(s: String) -> Box<dyn Error> {
    s.into()
}

pub(crate) fn fixed<const N: usize>(b: &[u8]) -> Result<[u8; N]> {
    <[u8; N]>::try_from(b).map_err(|_| boxed(format!("expected {} bytes, got {}", N, b.len())))
}

pub(crate) fn fill_random(buf: &mut [u8]) -> Result<()> {
    getrandom::getrandom(buf).map_err(|e| boxed(format!("getrandom failed: {e}")))
}

/// A full identity: two key pairs (KEM for receiving, signature for sending).
pub struct Identity {
    pub kem_pk: Vec<u8>,
    pub sig_pk: Vec<u8>,
    pub kem_sk: Zeroizing<Vec<u8>>,
    pub sig_sk: Zeroizing<Vec<u8>>,
}

/// Result of opening an envelope: plaintext plus authenticated freshness data.
pub struct Opened {
    pub plaintext: Vec<u8>,
    /// Unix seconds the sender stamped (authenticated). Always present for v2.
    pub ts: Option<u64>,
    /// Random per-message id (authenticated), for replay detection.
    pub msg_id: Option<[u8; 16]>,
}

/// Generate a fresh identity using the OS CSPRNG.
pub fn keygen() -> Result<Identity> {
    let mut kseed = Zeroizing::new([0u8; 64]);
    fill_random(&mut *kseed)?;
    let kkp = mlkem1024::generate_key_pair(*kseed);

    let mut sseed = Zeroizing::new([0u8; 32]);
    fill_random(&mut *sseed)?;
    let dkp = ml_dsa_87::generate_key_pair(*sseed);

    Ok(Identity {
        kem_pk: kkp.public_key().as_slice().to_vec(),
        sig_pk: dkp.verification_key.as_ref().to_vec(),
        kem_sk: Zeroizing::new(kkp.private_key().as_slice().to_vec()),
        sig_sk: Zeroizing::new(dkp.signing_key.as_ref().to_vec()),
    })
}

/// SHA-256 fingerprint of (kem_pk || sig_pk), grouped hex for out-of-band check.
pub fn fingerprint(kem_pk: &[u8], sig_pk: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(kem_pk);
    h.update(sig_pk);
    let digest = h.finalize();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    hex.as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
}

// HKDF-SHA256 over the one-time shared secret -> 32-byte key + 12-byte nonce.
// Safe to derive the nonce here: the shared secret is fresh per message, so the
// (key, nonce) pair never repeats.
fn kdf(shared_secret: &[u8]) -> Result<(Zeroizing<[u8; 32]>, [u8; 12])> {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut okm = Zeroizing::new([0u8; 44]);
    hk.expand(DOMAIN, &mut *okm)
        .map_err(|_| boxed("hkdf expand failed".into()))?;
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&okm[0..32]);
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&okm[32..44]);
    Ok((key, nonce))
}

fn aead_aad(kem_ct: &[u8], meta: &[u8]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(7 + kem_ct.len() + meta.len());
    aad.extend_from_slice(MAGIC);
    aad.push(SUITE);
    aad.extend_from_slice(kem_ct);
    aad.extend_from_slice(meta);
    aad
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub(crate) fn put_lv16(out: &mut Vec<u8>, data: &[u8]) {
    out.extend_from_slice(&(data.len() as u16).to_be_bytes());
    out.extend_from_slice(data);
}

pub(crate) fn put_lv32(out: &mut Vec<u8>, data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
}

pub(crate) struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    pub(crate) fn new(b: &'a [u8]) -> Self {
        Self { b, i: 0 }
    }
    pub(crate) fn pos(&self) -> usize {
        self.i
    }
    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.i.checked_add(n).is_none_or(|end| end > self.b.len()) {
            return Err(boxed("envelope truncated".into()));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    pub(crate) fn take_lv16(&mut self) -> Result<&'a [u8]> {
        let l = u16::from_be_bytes(fixed::<2>(self.take(2)?)?) as usize;
        self.take(l)
    }
    pub(crate) fn take_lv32(&mut self) -> Result<&'a [u8]> {
        let l = u32::from_be_bytes(fixed::<4>(self.take(4)?)?) as usize;
        self.take(l)
    }
}

/// Seal `plaintext` to a recipient (their KEM public key), signed by the sender
/// (their ML-DSA signing key). Returns the raw binary envelope (no transport tag).
pub fn seal(recipient_kem_pk: &[u8], sender_sig_sk: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let pk = MlKem1024PublicKey::from(fixed::<KEM_PK>(recipient_kem_pk)?);
    if !mlkem1024::validate_public_key(&pk) {
        return Err(boxed("invalid recipient ML-KEM public key".into()));
    }

    let mut enc_rand = Zeroizing::new([0u8; 32]);
    fill_random(&mut *enc_rand)?;
    let (ct, ss) = mlkem1024::encapsulate(&pk, *enc_rand);
    let ss = Zeroizing::new(ss);
    let (key, nonce) = kdf(&*ss)?;

    let ct_bytes = ct.as_slice();

    // Authenticated freshness metadata: ts (now) || msg_id (random).
    let mut meta = Vec::with_capacity(META_LEN);
    meta.extend_from_slice(&now_unix().to_be_bytes());
    let mut msg_id = [0u8; 16];
    fill_random(&mut msg_id)?;
    meta.extend_from_slice(&msg_id);

    let aad = aead_aad(ct_bytes, &meta);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&*key));
    let aead_ct = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| boxed("AEAD seal failed".into()))?;

    // header = magic | suite | LV(kem_ct) | LV(meta) | LV(aead_ct) ; signed.
    let mut env = Vec::new();
    env.extend_from_slice(MAGIC);
    env.push(SUITE);
    put_lv16(&mut env, ct_bytes);
    put_lv16(&mut env, &meta);
    put_lv32(&mut env, &aead_ct);

    let sk = MLDSA87SigningKey::new(fixed::<SIG_SK>(sender_sig_sk)?);
    let mut sig_rand = Zeroizing::new([0u8; 32]);
    fill_random(&mut *sig_rand)?;
    let sig = ml_dsa_87::sign(&sk, &env, DOMAIN, *sig_rand)
        .map_err(|e| boxed(format!("ML-DSA sign failed: {e:?}")))?;

    put_lv16(&mut env, sig.as_ref());
    Ok(env)
}

/// Open a binary envelope: verify the sender's signature, then decapsulate with
/// the recipient's KEM secret key and decrypt. Signature is checked first.
/// Returns the plaintext plus authenticated freshness metadata (ts, msg_id).
/// Freshness/replay *policy* is left to the caller, which has the clock and any
/// seen-id store.
pub fn open(my_kem_sk: &[u8], sender_sig_pk: &[u8], envelope: &[u8]) -> Result<Opened> {
    let mut p = Parser::new(envelope);
    if p.take(6)? != MAGIC {
        return Err(boxed("bad magic (not a WAPQ1 envelope)".into()));
    }
    if p.take(1)?[0] != SUITE {
        return Err(boxed("unsupported suite".into()));
    }
    let kem_ct = p.take_lv16()?;
    let meta = p.take_lv16()?;
    let aead_ct = p.take_lv32()?;
    let signed_len = p.pos(); // magic..aead_ct is the signed region
    let sig = p.take_lv16()?;

    // 1) authenticate the sender before touching anything else.
    let vk = MLDSA87VerificationKey::new(fixed::<SIG_PK>(sender_sig_pk)?);
    let sig_obj = MLDSA87Signature::new(fixed::<SIG_LEN>(sig)?);
    ml_dsa_87::verify(&vk, &envelope[0..signed_len], DOMAIN, &sig_obj)
        .map_err(|e| boxed(format!("signature verification failed: {e:?}")))?;

    // 2) decapsulate and decrypt (meta is authenticated via the AAD).
    let sk = MlKem1024PrivateKey::from(fixed::<KEM_SK>(my_kem_sk)?);
    let ct_obj = MlKem1024Ciphertext::from(fixed::<KEM_CT>(kem_ct)?);
    let ss = Zeroizing::new(mlkem1024::decapsulate(&sk, &ct_obj));
    let (key, nonce) = kdf(&*ss)?;

    let aad = aead_aad(kem_ct, meta);
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&*key));
    let pt = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: aead_ct,
                aad: &aad,
            },
        )
        .map_err(|_| boxed("decryption/authentication failed".into()))?;

    // meta is now authenticated (signature + AEAD both covered it).
    let (ts, msg_id) = if meta.len() == META_LEN {
        let ts = u64::from_be_bytes(fixed::<8>(&meta[0..8])?);
        let id = fixed::<16>(&meta[8..24])?;
        (Some(ts), Some(id))
    } else {
        (None, None)
    };
    Ok(Opened {
        plaintext: pt,
        ts,
        msg_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    // RFC 5869 Test Case 1 (HKDF-SHA256).
    #[test]
    fn rfc5869_hkdf_sha256_tc1() {
        let ikm = [0x0bu8; 22];
        let salt: Vec<u8> = (0u8..=0x0c).collect();
        let info: Vec<u8> = (0xf0u8..=0xf9).collect();
        let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
        let mut okm = [0u8; 42];
        hk.expand(&info, &mut okm).unwrap();
        let expected = unhex(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
        );
        assert_eq!(okm.to_vec(), expected);
    }

    // RFC 8439 section 2.8.2 (ChaCha20-Poly1305 AEAD): check the Poly1305 tag.
    #[test]
    fn rfc8439_chacha20poly1305_tag() {
        let key: Vec<u8> = (0x80u8..=0x9f).collect();
        let nonce = unhex("070000004041424344454647");
        let aad = unhex("50515253c0c1c2c3c4c5c6c7");
        let pt = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let ct = cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: pt, aad: &aad })
            .unwrap();
        assert_eq!(ct.len(), pt.len() + 16);
        let expected_tag = unhex("1ae10b594f09e26a7e902ecbd0600691");
        assert_eq!(&ct[ct.len() - 16..], &expected_tag[..]);
    }

    fn gen() -> Identity {
        keygen().unwrap()
    }

    #[test]
    fn seal_open_roundtrip() {
        let bob = gen();
        let alice = gen();
        let msg = "olá mundo 🔐 pós-quântico".as_bytes();
        let env = seal(&bob.kem_pk, &alice.sig_sk, msg).unwrap();
        let opened = open(&bob.kem_sk, &alice.sig_pk, &env).unwrap();
        assert_eq!(opened.plaintext, msg);
    }

    #[test]
    fn freshness_metadata_present_and_unique() {
        let bob = gen();
        let alice = gen();
        let before = now_unix();
        let e1 = seal(&bob.kem_pk, &alice.sig_sk, b"a").unwrap();
        let e2 = seal(&bob.kem_pk, &alice.sig_sk, b"a").unwrap();
        let o1 = open(&bob.kem_sk, &alice.sig_pk, &e1).unwrap();
        let o2 = open(&bob.kem_sk, &alice.sig_pk, &e2).unwrap();
        // ts is authenticated and sane.
        assert!(o1.ts.unwrap() >= before);
        // each message carries a distinct random id (replay anchor).
        assert_ne!(o1.msg_id.unwrap(), o2.msg_id.unwrap());
        // flipping the authenticated meta region must break verification.
        let mut bad = e1.clone();
        // meta sits right after magic(6)+suite(1)+u16len+kem_ct(1568)+u16len.
        let off = 6 + 1 + 2 + 1568 + 2 + 4; // into the meta block
        bad[off] ^= 0x01;
        assert!(open(&bob.kem_sk, &alice.sig_pk, &bad).is_err());
    }

    #[test]
    fn tamper_is_rejected() {
        let bob = gen();
        let alice = gen();
        let mut env = seal(&bob.kem_pk, &alice.sig_sk, b"secret").unwrap();
        let mid = env.len() / 2;
        env[mid] ^= 0x01;
        assert!(open(&bob.kem_sk, &alice.sig_pk, &env).is_err());
    }

    #[test]
    fn wrong_sender_key_is_rejected() {
        let bob = gen();
        let alice = gen();
        let mallory = gen();
        let env = seal(&bob.kem_pk, &alice.sig_sk, b"hi").unwrap();
        // Verifying against the wrong signer's public key must fail.
        assert!(open(&bob.kem_sk, &mallory.sig_pk, &env).is_err());
    }

    #[test]
    fn wrong_recipient_cannot_decrypt() {
        let bob = gen();
        let carol = gen();
        let alice = gen();
        let env = seal(&bob.kem_pk, &alice.sig_sk, b"for bob only").unwrap();
        // Signature is valid (alice), but carol's KEM secret yields a different
        // shared secret, so the AEAD open must fail.
        assert!(open(&carol.kem_sk, &alice.sig_pk, &env).is_err());
    }
}

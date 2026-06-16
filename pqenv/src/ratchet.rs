// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
//
//! Forward-secure session layer for whatsappel (`WAPQR` v1).
//!
//! Two parts:
//!   1. An ephemeral-prekey bootstrap (PQXDH-style). The responder publishes a
//!      one-time ML-KEM-1024 prekey signed by its long-term ML-DSA-87 identity.
//!      The initiator verifies it, encapsulates, and signs the resulting init
//!      token with *its* identity. The responder decapsulates with the ephemeral
//!      secret and then **deletes** it. After that, neither party's long-term
//!      secret can recover the session seed — that is the forward-secrecy hinge.
//!   2. A symmetric hash ratchet over the seed. Each message advances a chain:
//!      `(ck', mk) = HKDF(ck)`, the message key `mk` is used once and dropped,
//!      and the previous chain key is overwritten. A bounded look-ahead cache of
//!      skipped message keys tolerates out-of-order / lost messages.
//!
//! Authentication is established once, at bootstrap, by the two signatures.
//! Per-message authenticity follows from the AEAD: only the two peers hold the
//! ratchet keys, so a successful open proves the message came from the peer.
//!
//! Non-goals (documented in the threat model): no continuous asymmetric ratchet,
//! hence no post-compromise security — a leaked chain key exposes every later
//! message in that session until a new session is bootstrapped.

use std::collections::BTreeMap;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use libcrux_ml_dsa::ml_dsa_87::{
    self, MLDSA87Signature, MLDSA87SigningKey, MLDSA87VerificationKey,
};
use libcrux_ml_kem::mlkem1024::{
    self, MlKem1024Ciphertext, MlKem1024PrivateKey, MlKem1024PublicKey,
};

use crate::{boxed, fill_random, put_lv16, put_lv32, Parser, Result};

const PREKEY_MAGIC: &[u8; 6] = b"WAPQRP";
const INIT_MAGIC: &[u8; 6] = b"WAPQRI";
const MSG_MAGIC: &[u8; 6] = b"WAPQRM";
const SESS_MAGIC: &[u8; 6] = b"WAPQRS";
const SUITE: u8 = 0x01;

/// ML-DSA contexts (domain separation between prekey and init signatures).
const PREKEY_CTX: &[u8] = b"WAPQR-prekey-v1";
const INIT_CTX: &[u8] = b"WAPQR-init-v1";
/// HKDF info strings.
const INFO_ROOT: &[u8] = b"WAPQR root v1";
const INFO_I2R: &[u8] = b"WAPQR chain I2R v1";
const INFO_R2I: &[u8] = b"WAPQR chain R2I v1";
const INFO_CK: &[u8] = b"WAPQR ck-step v1";
const INFO_MK: &[u8] = b"WAPQR mk v1";
const INFO_MSG: &[u8] = b"WAPQR msg-key v1";

/// Upper bound on message keys derived ahead in one step, and on the resident
/// skipped-key cache. Caps memory against a malicious large counter.
const MAX_SKIP: u32 = 512;

const ROLE_INITIATOR: u8 = 0;
const ROLE_RESPONDER: u8 = 1;
const DIR_I2R: u8 = 0; // initiator -> responder
const DIR_R2I: u8 = 1; // responder -> initiator

// ---- KEM/sig (de)serialization helpers -------------------------------------

fn kem_pk_from(b: &[u8]) -> Result<MlKem1024PublicKey> {
    Ok(MlKem1024PublicKey::from(crate::fixed::<1568>(b)?))
}
fn kem_sk_from(b: &[u8]) -> Result<MlKem1024PrivateKey> {
    Ok(MlKem1024PrivateKey::from(crate::fixed::<3168>(b)?))
}
fn kem_ct_from(b: &[u8]) -> Result<MlKem1024Ciphertext> {
    Ok(MlKem1024Ciphertext::from(crate::fixed::<1568>(b)?))
}
fn sig_sk_from(b: &[u8]) -> Result<MLDSA87SigningKey> {
    Ok(MLDSA87SigningKey::new(crate::fixed::<4896>(b)?))
}
fn sig_pk_from(b: &[u8]) -> Result<MLDSA87VerificationKey> {
    Ok(MLDSA87VerificationKey::new(crate::fixed::<2592>(b)?))
}
fn sig_from(b: &[u8]) -> Result<MLDSA87Signature> {
    Ok(MLDSA87Signature::new(crate::fixed::<4627>(b)?))
}

fn sign(sig_sk: &[u8], msg: &[u8], ctx: &[u8]) -> Result<Vec<u8>> {
    let sk = sig_sk_from(sig_sk)?;
    let mut rnd = Zeroizing::new([0u8; 32]);
    fill_random(&mut *rnd)?;
    let sig =
        ml_dsa_87::sign(&sk, msg, ctx, *rnd).map_err(|e| boxed(format!("ml-dsa sign: {e:?}")))?;
    Ok(sig.as_ref().to_vec())
}

fn verify(sig_pk: &[u8], msg: &[u8], ctx: &[u8], sig: &[u8]) -> Result<()> {
    let vk = sig_pk_from(sig_pk)?;
    let sig = sig_from(sig)?;
    ml_dsa_87::verify(&vk, msg, ctx, &sig).map_err(|e| boxed(format!("ml-dsa verify: {e:?}")))
}

// ---- KDF helpers ------------------------------------------------------------

fn hkdf_from(prk: &[u8]) -> Result<Hkdf<Sha256>> {
    Hkdf::<Sha256>::from_prk(prk).map_err(|_| boxed("hkdf: bad prk length".into()))
}

/// Derive a 32-byte subkey from a 32-byte chain/root key under `info`.
fn derive32(prk: &[u8], info: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let mut out = Zeroizing::new([0u8; 32]);
    hkdf_from(prk)?
        .expand(info, &mut *out)
        .map_err(|_| boxed("hkdf expand 32 failed".into()))?;
    Ok(out)
}

/// `(next chain key, message key)` from one symmetric ratchet step.
type CkMk = (Zeroizing<[u8; 32]>, Zeroizing<[u8; 32]>);

/// Symmetric ratchet step: chain key -> (next chain key, message key).
fn kdf_ck(ck: &[u8; 32]) -> Result<CkMk> {
    let nck = derive32(ck, INFO_CK)?;
    let mk = derive32(ck, INFO_MK)?;
    Ok((nck, mk))
}

/// Message key -> AEAD (key, nonce). `mk` is unique per (chain, counter), so the
/// derived (key, nonce) never repeats.
fn msg_key_nonce(mk: &[u8; 32]) -> Result<(Zeroizing<[u8; 32]>, [u8; 12])> {
    let mut okm = Zeroizing::new([0u8; 44]);
    hkdf_from(mk)?
        .expand(INFO_MSG, &mut *okm)
        .map_err(|_| boxed("hkdf expand msg failed".into()))?;
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&okm[0..32]);
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&okm[32..44]);
    Ok((key, nonce))
}

fn msg_aad(sid: &[u8; 16], dir: u8, n: u32) -> Vec<u8> {
    let mut aad = Vec::with_capacity(6 + 1 + 16 + 1 + 4);
    aad.extend_from_slice(MSG_MAGIC);
    aad.push(SUITE);
    aad.extend_from_slice(sid);
    aad.push(dir);
    aad.extend_from_slice(&n.to_be_bytes());
    aad
}

// ---- Session ----------------------------------------------------------------

/// A live ratchet session. Holds secret chain keys; serialize to a 0600 file.
pub struct Session {
    role: u8,
    sid: [u8; 16],
    send_ck: Zeroizing<[u8; 32]>,
    recv_ck: Zeroizing<[u8; 32]>,
    send_n: u32,
    recv_n: u32,
    skipped: BTreeMap<u32, Zeroizing<[u8; 32]>>,
}

impl Session {
    fn from_seed(ss: &[u8], sid: [u8; 16], role: u8) -> Result<Self> {
        // root = HKDF(salt=None, ikm=ss).expand(INFO_ROOT)
        let mut root = Zeroizing::new([0u8; 32]);
        Hkdf::<Sha256>::new(None, ss)
            .expand(INFO_ROOT, &mut *root)
            .map_err(|_| boxed("hkdf root failed".into()))?;
        let i2r = derive32(&root[..], INFO_I2R)?;
        let r2i = derive32(&root[..], INFO_R2I)?;
        let (send_ck, recv_ck) = if role == ROLE_INITIATOR {
            (i2r, r2i)
        } else {
            (r2i, i2r)
        };
        Ok(Session {
            role,
            sid,
            send_ck,
            recv_ck,
            send_n: 0,
            recv_n: 0,
            skipped: BTreeMap::new(),
        })
    }

    fn send_dir(&self) -> u8 {
        if self.role == ROLE_INITIATOR {
            DIR_I2R
        } else {
            DIR_R2I
        }
    }
    fn recv_dir(&self) -> u8 {
        if self.role == ROLE_INITIATOR {
            DIR_R2I
        } else {
            DIR_I2R
        }
    }

    /// Serialize the session (secret-bearing; caller must store at mode 0600).
    pub fn to_bytes(&self) -> Zeroizing<Vec<u8>> {
        let mut out = Vec::new();
        out.extend_from_slice(SESS_MAGIC);
        out.push(SUITE);
        out.push(self.role);
        out.extend_from_slice(&self.sid);
        out.extend_from_slice(&self.send_n.to_be_bytes());
        out.extend_from_slice(&self.recv_n.to_be_bytes());
        out.extend_from_slice(&*self.send_ck);
        out.extend_from_slice(&*self.recv_ck);
        out.extend_from_slice(&(self.skipped.len() as u32).to_be_bytes());
        for (n, mk) in &self.skipped {
            out.extend_from_slice(&n.to_be_bytes());
            out.extend_from_slice(&**mk);
        }
        Zeroizing::new(out)
    }

    /// Parse a session previously produced by [`Session::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut p = Parser::new(b);
        if p.take(6)? != SESS_MAGIC {
            return Err(boxed("not a WAPQR session".into()));
        }
        if p.take(1)?[0] != SUITE {
            return Err(boxed("unsupported session suite".into()));
        }
        let role = p.take(1)?[0];
        if role != ROLE_INITIATOR && role != ROLE_RESPONDER {
            return Err(boxed("invalid session role".into()));
        }
        let sid = crate::fixed::<16>(p.take(16)?)?;
        let send_n = u32::from_be_bytes(crate::fixed::<4>(p.take(4)?)?);
        let recv_n = u32::from_be_bytes(crate::fixed::<4>(p.take(4)?)?);
        let mut send_ck = Zeroizing::new([0u8; 32]);
        send_ck.copy_from_slice(p.take(32)?);
        let mut recv_ck = Zeroizing::new([0u8; 32]);
        recv_ck.copy_from_slice(p.take(32)?);
        let count = u32::from_be_bytes(crate::fixed::<4>(p.take(4)?)?);
        if count > MAX_SKIP {
            return Err(boxed("session skipped-key count exceeds bound".into()));
        }
        let mut skipped = BTreeMap::new();
        for _ in 0..count {
            let n = u32::from_be_bytes(crate::fixed::<4>(p.take(4)?)?);
            let mut mk = Zeroizing::new([0u8; 32]);
            mk.copy_from_slice(p.take(32)?);
            skipped.insert(n, mk);
        }
        Ok(Session {
            role,
            sid,
            send_ck,
            recv_ck,
            send_n,
            recv_n,
            skipped,
        })
    }

    /// Encrypt `plaintext` as the next outbound message, advancing the send chain.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let (nck, mk) = kdf_ck(&self.send_ck)?;
        let n = self.send_n;
        let dir = self.send_dir();
        let (key, nonce) = msg_key_nonce(&mk)?;
        let aad = msg_aad(&self.sid, dir, n);
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&*key));
        let ct = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| boxed("aead encrypt failed".into()))?;
        let mut out = Vec::with_capacity(6 + 1 + 16 + 1 + 4 + 4 + ct.len());
        out.extend_from_slice(MSG_MAGIC);
        out.push(SUITE);
        out.extend_from_slice(&self.sid);
        out.push(dir);
        out.extend_from_slice(&n.to_be_bytes());
        put_lv32(&mut out, &ct);
        // Commit only after success.
        self.send_ck = nck;
        self.send_n = self
            .send_n
            .checked_add(1)
            .ok_or_else(|| boxed("send counter overflow".into()))?;
        Ok(out)
    }

    /// Verify+decrypt an inbound message, advancing/repairing the receive chain.
    /// Returns the plaintext, or [`RecvError`] for replay / out-of-window / forged
    /// messages. On any error the session state is left unchanged.
    pub fn decrypt(&mut self, msg: &[u8]) -> std::result::Result<Vec<u8>, RecvError> {
        let mut p = Parser::new(msg);
        if p.take(6).map_err(|_| RecvError::Malformed)? != MSG_MAGIC {
            return Err(RecvError::Malformed);
        }
        if p.take(1).map_err(|_| RecvError::Malformed)?[0] != SUITE {
            return Err(RecvError::Malformed);
        }
        let sid = p.take(16).map_err(|_| RecvError::Malformed)?;
        if sid != self.sid {
            return Err(RecvError::WrongSession);
        }
        let dir = p.take(1).map_err(|_| RecvError::Malformed)?[0];
        if dir != self.recv_dir() {
            // Either our own direction (reflection) or garbage.
            return Err(RecvError::WrongDirection);
        }
        let n = u32::from_be_bytes(
            crate::fixed::<4>(p.take(4).map_err(|_| RecvError::Malformed)?)
                .map_err(|_| RecvError::Malformed)?,
        );
        let ct = p.take_lv32().map_err(|_| RecvError::Malformed)?;
        let aad = msg_aad(&self.sid, dir, n);

        // Case 1: a previously skipped message.
        if n < self.recv_n {
            let mk = self.skipped.get(&n).ok_or(RecvError::Replay)?;
            let pt = aead_open(mk, &aad, ct).map_err(|_| RecvError::AeadFailed)?;
            self.skipped.remove(&n); // one-time use
            return Ok(pt);
        }

        // Case 2: at or ahead of the expected counter. Derive on a clone and
        // commit only if the AEAD succeeds, so a forged message cannot desync us.
        let ahead = n - self.recv_n;
        if ahead > MAX_SKIP {
            return Err(RecvError::TooFarAhead);
        }
        let mut ck = Zeroizing::new(*self.recv_ck);
        let mut staged: Vec<(u32, Zeroizing<[u8; 32]>)> = Vec::new();
        for i in self.recv_n..n {
            let (nck, mk) = kdf_ck(&ck).map_err(|_| RecvError::AeadFailed)?;
            staged.push((i, mk));
            ck = nck;
        }
        let (nck, mk) = kdf_ck(&ck).map_err(|_| RecvError::AeadFailed)?;
        let pt = aead_open(&mk, &aad, ct).map_err(|_| RecvError::AeadFailed)?;
        // Commit.
        for (i, k) in staged {
            self.skipped.insert(i, k);
        }
        self.prune_skipped();
        self.recv_ck = nck;
        self.recv_n = n.checked_add(1).ok_or(RecvError::Malformed)?;
        Ok(pt)
    }

    fn prune_skipped(&mut self) {
        while self.skipped.len() as u32 > MAX_SKIP {
            if let Some((&first, _)) = self.skipped.iter().next() {
                self.skipped.remove(&first);
            } else {
                break;
            }
        }
    }
}

fn aead_open(mk: &[u8; 32], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    let (key, nonce) = msg_key_nonce(mk)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&*key));
    cipher
        .decrypt(Nonce::from_slice(&nonce), Payload { msg: ct, aad })
        .map_err(|_| boxed("aead decrypt failed".into()))
}

/// Reasons an inbound message is rejected. The CLI maps all of these to exit 3.
#[derive(Debug, PartialEq, Eq)]
pub enum RecvError {
    Malformed,
    WrongSession,
    WrongDirection,
    Replay,
    TooFarAhead,
    AeadFailed,
}

impl std::fmt::Display for RecvError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            RecvError::Malformed => "malformed message",
            RecvError::WrongSession => "message is for a different session",
            RecvError::WrongDirection => "wrong direction (reflected or own message)",
            RecvError::Replay => "replay or too-old message (key already consumed)",
            RecvError::TooFarAhead => "counter too far ahead of session state",
            RecvError::AeadFailed => "authentication failed (forged or corrupt)",
        };
        f.write_str(s)
    }
}
impl std::error::Error for RecvError {}

// ---- Prekey + handshake -----------------------------------------------------

/// Generate a one-time prekey: a fresh ephemeral ML-KEM keypair whose public key
/// is signed by `identity_sig_sk`. Returns `(public_blob, secret_blob)`. Publish
/// the public blob; keep the secret blob (0600) until exactly one `accept`.
pub fn gen_prekey(identity_sig_sk: &[u8]) -> Result<(Vec<u8>, Zeroizing<Vec<u8>>)> {
    let mut seed = Zeroizing::new([0u8; 64]);
    fill_random(&mut *seed)?;
    let kp = mlkem1024::generate_key_pair(*seed);
    let kem_pk = kp.public_key().as_slice().to_vec();
    let kem_sk = Zeroizing::new(kp.private_key().as_slice().to_vec());

    let mut signed = Vec::with_capacity(6 + kem_pk.len());
    signed.extend_from_slice(PREKEY_MAGIC);
    signed.extend_from_slice(&kem_pk);
    let sig = sign(identity_sig_sk, &signed, PREKEY_CTX)?;

    let mut pubb = Vec::new();
    pubb.extend_from_slice(PREKEY_MAGIC);
    pubb.push(SUITE);
    put_lv16(&mut pubb, &kem_pk);
    put_lv16(&mut pubb, &sig);

    let mut secb = Vec::new();
    secb.extend_from_slice(PREKEY_MAGIC);
    secb.push(0x00); // secret marker
    put_lv16(&mut secb, &kem_sk);
    Ok((pubb, Zeroizing::new(secb)))
}

fn parse_prekey_public(blob: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut p = Parser::new(blob);
    if p.take(6)? != PREKEY_MAGIC || p.take(1)?[0] != SUITE {
        return Err(boxed("not a WAPQR prekey".into()));
    }
    let kem_pk = p.take_lv16()?.to_vec();
    let sig = p.take_lv16()?.to_vec();
    Ok((kem_pk, sig))
}

fn parse_prekey_secret(blob: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let mut p = Parser::new(blob);
    if p.take(6)? != PREKEY_MAGIC || p.take(1)?[0] != 0x00 {
        return Err(boxed("not a WAPQR prekey secret".into()));
    }
    Ok(Zeroizing::new(p.take_lv16()?.to_vec()))
}

/// Initiator side. Verify the responder's prekey (signed by `peer_sig_pk`),
/// encapsulate to it, and sign the init token with `my_sig_sk`. Returns the
/// initiator session and the init token to hand to the responder.
pub fn init(
    my_sig_sk: &[u8],
    peer_sig_pk: &[u8],
    prekey_public: &[u8],
) -> Result<(Zeroizing<Vec<u8>>, Vec<u8>)> {
    let (kem_pk, presig) = parse_prekey_public(prekey_public)?;
    let mut signed = Vec::with_capacity(6 + kem_pk.len());
    signed.extend_from_slice(PREKEY_MAGIC);
    signed.extend_from_slice(&kem_pk);
    verify(peer_sig_pk, &signed, PREKEY_CTX, &presig)?;

    let pk = kem_pk_from(&kem_pk)?;
    if !mlkem1024::validate_public_key(&pk) {
        return Err(boxed("invalid prekey ML-KEM public key".into()));
    }
    let mut enc_rand = Zeroizing::new([0u8; 32]);
    fill_random(&mut *enc_rand)?;
    let (ct, ss) = mlkem1024::encapsulate(&pk, *enc_rand);
    let ss = Zeroizing::new(ss);
    let ct_bytes = ct.as_slice();

    let mut sid = [0u8; 16];
    fill_random(&mut sid)?;

    let mut signed_init = Vec::with_capacity(6 + 16 + ct_bytes.len());
    signed_init.extend_from_slice(INIT_MAGIC);
    signed_init.extend_from_slice(&sid);
    signed_init.extend_from_slice(ct_bytes);
    let sig = sign(my_sig_sk, &signed_init, INIT_CTX)?;

    let mut token = Vec::new();
    token.extend_from_slice(INIT_MAGIC);
    token.push(SUITE);
    token.extend_from_slice(&sid);
    put_lv16(&mut token, ct_bytes);
    put_lv16(&mut token, &sig);

    let sess = Session::from_seed(&*ss, sid, ROLE_INITIATOR)?;
    Ok((sess.to_bytes(), token))
}

/// Responder side. Verify the init token (signed by `peer_sig_pk`, the
/// initiator), decapsulate with the one-time prekey secret, and build the
/// responder session. The caller must delete the prekey secret afterwards.
pub fn accept(
    peer_sig_pk: &[u8],
    prekey_secret: &[u8],
    init_token: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    let mut p = Parser::new(init_token);
    if p.take(6)? != INIT_MAGIC || p.take(1)?[0] != SUITE {
        return Err(boxed("not a WAPQR init token".into()));
    }
    let sid = crate::fixed::<16>(p.take(16)?)?;
    let ct_bytes = p.take_lv16()?.to_vec();
    let sig = p.take_lv16()?.to_vec();

    let mut signed_init = Vec::with_capacity(6 + 16 + ct_bytes.len());
    signed_init.extend_from_slice(INIT_MAGIC);
    signed_init.extend_from_slice(&sid);
    signed_init.extend_from_slice(&ct_bytes);
    verify(peer_sig_pk, &signed_init, INIT_CTX, &sig)?;

    let kem_sk = parse_prekey_secret(prekey_secret)?;
    let sk = kem_sk_from(&kem_sk)?;
    let ct = kem_ct_from(&ct_bytes)?;
    let ss = Zeroizing::new(mlkem1024::decapsulate(&sk, &ct));

    let sess = Session::from_seed(&*ss, sid, ROLE_RESPONDER)?;
    Ok(sess.to_bytes())
}

#[cfg(test)]
mod rtests {
    use super::*;
    use crate::keygen;

    // Bootstrap a connected (initiator, responder) session pair.
    fn pair() -> (Zeroizing<Vec<u8>>, Zeroizing<Vec<u8>>) {
        let a = keygen().unwrap(); // initiator
        let b = keygen().unwrap(); // responder
        let (prekey_pub, prekey_sec) = gen_prekey(&b.sig_sk).unwrap();
        let (a_sess, token) = init(&a.sig_sk, &b.sig_pk, &prekey_pub).unwrap();
        let b_sess = accept(&a.sig_pk, &prekey_sec, &token).unwrap();
        (a_sess, b_sess)
    }

    fn send(blob: &Zeroizing<Vec<u8>>, pt: &[u8]) -> (Zeroizing<Vec<u8>>, Vec<u8>) {
        let mut s = Session::from_bytes(blob).unwrap();
        let msg = s.encrypt(pt).unwrap();
        (s.to_bytes(), msg)
    }
    fn recv(
        blob: &Zeroizing<Vec<u8>>,
        msg: &[u8],
    ) -> (Zeroizing<Vec<u8>>, std::result::Result<Vec<u8>, RecvError>) {
        let mut s = Session::from_bytes(blob).unwrap();
        let r = s.decrypt(msg);
        (s.to_bytes(), r)
    }

    #[test]
    fn bootstrap_chains_mirror() {
        // A's send chain must equal B's receive chain and vice-versa: a message
        // each way decrypts.
        let (mut a, mut b) = pair();
        let (a2, m) = send(&a, b"ping from A");
        a = a2;
        let (b2, r) = recv(&b, &m);
        b = b2;
        assert_eq!(r.unwrap(), b"ping from A");
        let (b3, m2) = send(&b, b"pong from B");
        let _ = &b3;
        let (_a3, r2) = recv(&a, &m2);
        assert_eq!(r2.unwrap(), b"pong from B");
    }

    #[test]
    fn in_order_stream() {
        let (mut a, mut b) = pair();
        for i in 0..50u32 {
            let pt = format!("msg {i}");
            let (a2, m) = send(&a, pt.as_bytes());
            a = a2;
            let (b2, r) = recv(&b, &m);
            b = b2;
            assert_eq!(r.unwrap(), pt.as_bytes());
        }
    }

    #[test]
    fn out_of_order_within_window() {
        let (a, mut b) = pair();
        // A produces 0,1,2 (advancing A's own state each time).
        let (a1, m0) = send(&a, b"zero");
        let (a2, m1) = send(&a1, b"one");
        let (_a3, m2) = send(&a2, b"two");
        // B receives 2 first (skips 0,1), then 0, then 1.
        let (b1, r2) = recv(&b, &m2);
        b = b1;
        assert_eq!(r2.unwrap(), b"two");
        let (b2, r0) = recv(&b, &m0);
        b = b2;
        assert_eq!(r0.unwrap(), b"zero");
        let (b3, r1) = recv(&b, &m1);
        let _ = &b3;
        assert_eq!(r1.unwrap(), b"one");
    }

    #[test]
    fn replay_is_rejected() {
        let (a, b) = pair();
        let (_a1, m0) = send(&a, b"once");
        let (b1, r0) = recv(&b, &m0);
        assert_eq!(r0.unwrap(), b"once");
        // Same ciphertext again on the advanced state -> rejected.
        let (_b2, r0b) = recv(&b1, &m0);
        assert_eq!(r0b.unwrap_err(), RecvError::Replay);
    }

    #[test]
    fn skipped_then_replayed_rejected() {
        let (a, b) = pair();
        let (a1, m0) = send(&a, b"zero");
        let (_a2, m1) = send(&a1, b"one");
        // Receive 1 first (0 stored as skipped), then 0, then 0 again.
        let (b1, _) = recv(&b, &m1);
        let (b2, r0) = recv(&b1, &m0);
        assert_eq!(r0.unwrap(), b"zero");
        let (_b3, r0b) = recv(&b2, &m0);
        assert_eq!(r0b.unwrap_err(), RecvError::Replay);
    }

    #[test]
    fn too_far_ahead_rejected() {
        let (a, b) = pair();
        // Advance A past MAX_SKIP without delivering, then deliver the far msg.
        let mut s = Session::from_bytes(&a).unwrap();
        let mut far = Vec::new();
        for _ in 0..=(MAX_SKIP + 1) {
            far = s.encrypt(b"x").unwrap();
        }
        let (_b1, r) = recv(&b, &far);
        assert_eq!(r.unwrap_err(), RecvError::TooFarAhead);
    }

    #[test]
    fn tamper_is_rejected() {
        let (a, b) = pair();
        let (_a1, mut m) = send(&a, b"integrity");
        let last = m.len() - 1;
        m[last] ^= 0x01;
        let (_b1, r) = recv(&b, &m);
        assert_eq!(r.unwrap_err(), RecvError::AeadFailed);
    }

    #[test]
    fn reflection_is_rejected() {
        // A's own outbound message fed back to A must not decrypt (direction tag).
        let (a, _b) = pair();
        let (a1, m) = send(&a, b"echo");
        let (_a2, r) = recv(&a1, &m);
        assert_eq!(r.unwrap_err(), RecvError::WrongDirection);
    }

    #[test]
    fn wrong_session_rejected() {
        let (a1, _b1) = pair();
        let (_a2, _b2) = pair();
        // A message from session #1 ...
        let (_a1b, m) = send(&a1, b"hi");
        // ... fed to a fresh, unrelated responder (#2) -> different sid.
        let b2_other = {
            let a = keygen().unwrap();
            let b = keygen().unwrap();
            let (pk, sec) = gen_prekey(&b.sig_sk).unwrap();
            let (_as, tok) = init(&a.sig_sk, &b.sig_pk, &pk).unwrap();
            accept(&a.sig_pk, &sec, &tok).unwrap()
        };
        let (_b, r) = recv(&b2_other, &m);
        assert_eq!(r.unwrap_err(), RecvError::WrongSession);
    }

    #[test]
    fn forged_prekey_rejected() {
        // A prekey signed by someone other than the claimed responder is refused.
        let a = keygen().unwrap();
        let b = keygen().unwrap();
        let evil = keygen().unwrap();
        let (prekey_pub, _sec) = gen_prekey(&evil.sig_sk).unwrap(); // signed by evil
        let err = init(&a.sig_sk, &b.sig_pk, &prekey_pub).unwrap_err();
        assert!(err.to_string().contains("verify"));
    }

    #[test]
    fn forged_init_rejected() {
        // An init token not signed by the claimed initiator is refused.
        let a = keygen().unwrap();
        let b = keygen().unwrap();
        let evil = keygen().unwrap();
        let (prekey_pub, prekey_sec) = gen_prekey(&b.sig_sk).unwrap();
        let (_as, token) = init(&evil.sig_sk, &b.sig_pk, &prekey_pub).unwrap();
        // Responder expects the token to be signed by `a`, not `evil`.
        let err = accept(&a.sig_pk, &prekey_sec, &token).unwrap_err();
        assert!(err.to_string().contains("verify"));
    }

    #[test]
    fn forward_secrecy_old_key_gone() {
        // After consuming msg 0 in order, the advanced session cannot decrypt a
        // re-sent msg 0 (its key was used once and dropped, not retained).
        let (a, b) = pair();
        let (a1, m0) = send(&a, b"secret zero");
        let (_a2, m1) = send(&a1, b"one");
        let (b1, r0) = recv(&b, &m0);
        assert_eq!(r0.unwrap(), b"secret zero");
        let (b2, r1) = recv(&b1, &m1);
        assert_eq!(r1.unwrap(), b"one");
        // b2 has advanced past 0 with no skipped entry for it.
        let (_b3, again) = recv(&b2, &m0);
        assert_eq!(again.unwrap_err(), RecvError::Replay);
    }

    #[test]
    fn session_roundtrips_through_bytes() {
        let (a, b) = pair();
        // Serialize/parse mid-stream and continue.
        let (a1, m0) = send(&a, b"a");
        let s = Session::from_bytes(&a1).unwrap();
        let reser = s.to_bytes();
        let (b1, r0) = recv(&b, &m0);
        assert_eq!(r0.unwrap(), b"a");
        let (_a2, m1) = send(&reser, b"b");
        let (_b2, r1) = recv(&b1, &m1);
        assert_eq!(r1.unwrap(), b"b");
    }
}

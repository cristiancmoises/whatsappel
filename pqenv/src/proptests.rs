// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
//
//! Property-based tests: parser panic-safety on arbitrary input (DoS surface)
//! plus roundtrip / out-of-order invariants for the envelope and the ratchet.
//! These complement the deterministic unit tests with randomized coverage.

use std::sync::OnceLock;

use proptest::prelude::*;

use crate::ratchet;
use crate::{keygen, open, seal, Identity};

// One identity pair, generated once (keygen is comparatively expensive).
fn parties() -> &'static (Identity, Identity) {
    static P: OnceLock<(Identity, Identity)> = OnceLock::new();
    P.get_or_init(|| (keygen().unwrap(), keygen().unwrap()))
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    /// Envelope: seal then open returns the exact plaintext for any input.
    #[test]
    fn envelope_roundtrip(pt in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let (a, b) = parties();           // a = sender, b = recipient
        let env = seal(&b.kem_pk, &a.sig_sk, &pt).unwrap();
        let opened = open(&b.kem_sk, &a.sig_pk, &env).unwrap();
        prop_assert_eq!(opened.plaintext, pt);
    }

    /// open() must never panic on arbitrary bytes; it rejects non-envelopes.
    #[test]
    fn open_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..8192)) {
        let (a, b) = parties();
        let _ = open(&b.kem_sk, &a.sig_pk, &bytes); // Ok or Err, never a panic.
    }

    /// A genuine envelope with one mutated byte must be rejected (never decrypt).
    #[test]
    fn envelope_single_bit_flip_rejected(
        pt in proptest::collection::vec(any::<u8>(), 1..512),
        idx in any::<usize>(),
        bit in 0u32..8,
    ) {
        let (a, b) = parties();
        let mut env = seal(&b.kem_pk, &a.sig_sk, &pt).unwrap();
        let i = idx % env.len();
        env[i] ^= 1u8 << bit;
        // Either rejected, or (astronomically unlikely) still authenticates to
        // the same plaintext; never a different plaintext, never a panic.
        if let Ok(o) = open(&b.kem_sk, &a.sig_pk, &env) {
            prop_assert_eq!(o.plaintext, pt);
        }
    }

    /// Session::from_bytes must never panic on arbitrary bytes.
    #[test]
    fn session_from_bytes_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let _ = ratchet::Session::from_bytes(&bytes);
    }

    /// accept()/init parsers must never panic on arbitrary token bytes.
    #[test]
    fn accept_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let (a, _b) = parties();
        // peer_sig_pk valid length, arbitrary "prekey secret" and "init token".
        let _ = ratchet::accept(&a.sig_pk, &bytes, &bytes);
    }
}

// Build a connected initiator/responder session pair for ratchet properties.
fn ratchet_pair() -> (Vec<u8>, Vec<u8>) {
    let a = keygen().unwrap();
    let b = keygen().unwrap();
    let (prekey_pub, prekey_sec) = ratchet::gen_prekey(&b.sig_sk).unwrap();
    let (a_sess, token) = ratchet::init(&a.sig_sk, &b.sig_pk, &prekey_pub).unwrap();
    let b_sess = ratchet::accept(&a.sig_pk, &prekey_sec, &token).unwrap();
    (a_sess.to_vec(), b_sess.to_vec())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    /// decrypt() on a live session must never panic on arbitrary bytes.
    #[test]
    fn ratchet_decrypt_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let (_a, b) = ratchet_pair();
        let mut s = ratchet::Session::from_bytes(&b).unwrap();
        let _ = s.decrypt(&bytes);
    }

    /// Messages sent in order but DELIVERED in an arbitrary permutation (within
    /// the skip window) all decrypt to their original plaintext exactly once.
    #[test]
    fn ratchet_out_of_order_permutation(
        msgs in proptest::collection::vec(
            proptest::collection::vec(any::<u8>(), 0..64), 1..24),
        order_keys in proptest::collection::vec(any::<u64>(), 24),
    ) {
        let (a, b) = ratchet_pair();
        // Sender encrypts all messages in order.
        let mut sa = ratchet::Session::from_bytes(&a).unwrap();
        let mut wire: Vec<(usize, Vec<u8>)> = Vec::new();
        for (i, m) in msgs.iter().enumerate() {
            wire.push((i, sa.encrypt(m).unwrap()));
        }
        // Deliver in a permutation derived from random keys.
        let mut idx: Vec<usize> = (0..wire.len()).collect();
        idx.sort_by_key(|&i| order_keys[i % order_keys.len()]);

        let mut sb = ratchet::Session::from_bytes(&b).unwrap();
        for &i in &idx {
            let (orig, msg) = &wire[i];
            let pt = sb.decrypt(msg).expect("in-window message must decrypt");
            prop_assert_eq!(&pt, &msgs[*orig]);
        }
        // Re-delivering any message now must be rejected (one-time keys).
        for (_orig, msg) in &wire {
            prop_assert!(sb.decrypt(msg).is_err());
        }
    }
}

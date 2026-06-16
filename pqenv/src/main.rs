// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
//
//! `pqenv` CLI: post-quantum message envelopes for whatsappel.
//!
//!   pqenv keygen --out NAME
//!   pqenv seal   --recipient NAME.public --identity ME.secret [--in F] [--out F]
//!   pqenv open   --identity ME.secret    --sender BOB.public  [--in F] [--out F]
//!   pqenv fingerprint NAME.public

#![forbid(unsafe_code)]

use std::fmt::Write as _;
use std::fs;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use zeroize::Zeroizing;

use pqenv::{fingerprint, keygen, open, ratchet, seal, Result, TRANSPORT_PREFIX};

const USAGE: &str = "\
pqenv - post-quantum message envelope (ML-KEM-1024 + ML-DSA-87 + ChaCha20-Poly1305)

USAGE:
  pqenv keygen --out NAME
      Write NAME.public (shareable) and NAME.secret (mode 0600).
  pqenv seal --recipient NAME.public --identity ME.secret [--in FILE] [--out FILE]
      Encrypt stdin/--in to the recipient, signed by ME. Emits a WAPQ1: blob.
  pqenv open --identity ME.secret --sender BOB.public [--in FILE] [--out FILE] \\
             [--max-age SECONDS] [--seen FILE]
      Verify BOB's signature and decrypt a WAPQ1: blob to stdout/--out.
      --max-age rejects messages whose timestamp is outside the window;
      --seen FILE rejects replays (duplicate msg_id). Both exit 3 on rejection.
  pqenv fingerprint NAME.public
      Print the SHA-256 fingerprint of a public key for out-of-band checking.

  Forward-secure sessions (WAPQR) — opt-in, stateful, 1:1:
  pqenv ratchet-prekey --identity ME.secret --out NAME
      Write NAME.prekey (one-time, shareable) and NAME.prekey.secret (0600).
  pqenv ratchet-init --identity ME.secret --peer PEER.public \\
                     --prekey PEER.prekey --session OUT.session [--out INITFILE]
      Verify PEER's prekey, encapsulate, emit a signed init token, write session.
  pqenv ratchet-accept --peer PEER.public --prekey-secret NAME.prekey.secret \\
                       --init INITFILE --session OUT.session
      Verify the init token, decapsulate, write session; deletes the prekey secret.
  pqenv ratchet-send --session S.session [--in FILE] [--out FILE]
      Encrypt the next message, advancing the session (written back, 0600).
  pqenv ratchet-recv --session S.session [--in FILE] [--out FILE]
      Decrypt an inbound message; advances the session on success, exit 3 on
      replay / out-of-window / forged messages.
";

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

fn read_input(args: &[String]) -> Result<Vec<u8>> {
    if let Some(path) = flag(args, "--in") {
        Ok(fs::read(path)?)
    } else {
        let mut buf = Vec::new();
        std::io::stdin().read_to_end(&mut buf)?;
        Ok(buf)
    }
}

fn write_output(args: &[String], data: &[u8]) -> Result<()> {
    if let Some(path) = flag(args, "--out") {
        fs::write(path, data)?;
    } else {
        std::io::stdout().write_all(data)?;
    }
    Ok(())
}

fn write_public(path: &str, kem_pk: &[u8], sig_pk: &[u8]) -> Result<()> {
    let body = format!(
        "pqenv-public-v1\nkem_pk: {}\nsig_pk: {}\n",
        B64.encode(kem_pk),
        B64.encode(sig_pk)
    );
    fs::write(path, body)?;
    Ok(())
}

fn write_secret(
    path: &str,
    kem_sk: &[u8],
    sig_sk: &[u8],
    kem_pk: &[u8],
    sig_pk: &[u8],
) -> Result<()> {
    let body = Zeroizing::new(format!(
        "pqenv-secret-v1\nkem_sk: {}\nsig_sk: {}\nkem_pk: {}\nsig_pk: {}\n",
        B64.encode(kem_sk),
        B64.encode(sig_sk),
        B64.encode(kem_pk),
        B64.encode(sig_pk)
    ));
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(body.as_bytes())?;
    Ok(())
}

// Parse a key file into (label, bytes) pairs.
fn read_keyfile(path: &str) -> Result<Vec<(String, Vec<u8>)>> {
    let text = Zeroizing::new(fs::read_to_string(path)?);
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some((label, value)) = line.split_once(": ") {
            let bytes = B64
                .decode(value.trim())
                .map_err(|e| format!("{path}: bad base64 for {label}: {e}"))?;
            out.push((label.trim().to_string(), bytes));
        }
    }
    Ok(out)
}

fn field(fields: &[(String, Vec<u8>)], label: &str) -> Result<Vec<u8>> {
    fields
        .iter()
        .find(|(k, _)| k == label)
        .map(|(_, v)| v.clone())
        .ok_or_else(|| format!("missing '{label}' in key file").into())
}

fn cmd_keygen(args: &[String]) -> Result<()> {
    let out = flag(args, "--out").ok_or("keygen requires --out NAME")?;
    let id = keygen()?;
    write_public(&format!("{out}.public"), &id.kem_pk, &id.sig_pk)?;
    write_secret(
        &format!("{out}.secret"),
        &id.kem_sk,
        &id.sig_sk,
        &id.kem_pk,
        &id.sig_pk,
    )?;
    eprintln!("wrote {out}.public and {out}.secret (0600)");
    eprintln!("fingerprint: {}", fingerprint(&id.kem_pk, &id.sig_pk));
    Ok(())
}

fn cmd_seal(args: &[String]) -> Result<()> {
    let rcpt = flag(args, "--recipient").ok_or("seal requires --recipient NAME.public")?;
    let ident = flag(args, "--identity").ok_or("seal requires --identity ME.secret")?;
    let rfields = read_keyfile(&rcpt)?;
    let ifields = read_keyfile(&ident)?;
    let recipient_kem_pk = field(&rfields, "kem_pk")?;
    let sender_sig_sk = Zeroizing::new(field(&ifields, "sig_sk")?);
    let plaintext = Zeroizing::new(read_input(args)?);
    let env = seal(&recipient_kem_pk, &sender_sig_sk, &plaintext)?;
    let mut out = format!("{TRANSPORT_PREFIX}{}", B64.encode(&env)).into_bytes();
    out.push(b'\n');
    write_output(args, &out)?;
    Ok(())
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn hex16(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        let _ = write!(s, "{x:02x}");
    }
    s
}

fn write_seen(path: &str, entries: &[(u64, String)]) -> Result<()> {
    let mut body = String::new();
    for (ts, id) in entries {
        let _ = writeln!(body, "{ts} {id}");
    }
    let tmp = format!("{path}.tmp");
    fs::write(&tmp, &body)?;
    fs::rename(&tmp, path)?;
    Ok(())
}

// Returns true if ID_HEX is new (and records it); false if it is a replay.
// Prunes entries older than MAX_AGE when given, bounding the store.
fn seen_check_and_record(
    path: &str,
    id_hex: &str,
    msg_ts: u64,
    max_age: Option<u64>,
) -> Result<bool> {
    let now = now_unix();
    let mut kept: Vec<(u64, String)> = Vec::new();
    let mut replay = false;
    if let Ok(text) = fs::read_to_string(path) {
        for line in text.lines() {
            if let Some((ts_s, id)) = line.split_once(' ') {
                let ts: u64 = ts_s.parse().unwrap_or(0);
                if let Some(age) = max_age {
                    if now.saturating_sub(ts) > age {
                        continue; // prune stale entry
                    }
                }
                if id == id_hex {
                    replay = true;
                }
                kept.push((ts, id.to_string()));
            }
        }
    }
    if replay {
        write_seen(path, &kept)?; // persist the pruned set
        return Ok(false);
    }
    kept.push((msg_ts, id_hex.to_string()));
    write_seen(path, &kept)?;
    Ok(true)
}

fn cmd_open(args: &[String]) -> Result<()> {
    let ident = flag(args, "--identity").ok_or("open requires --identity ME.secret")?;
    let sender = flag(args, "--sender").ok_or("open requires --sender BOB.public")?;
    let ifields = read_keyfile(&ident)?;
    let sfields = read_keyfile(&sender)?;
    let my_kem_sk = Zeroizing::new(field(&ifields, "kem_sk")?);
    let sender_sig_pk = field(&sfields, "sig_pk")?;

    let raw = read_input(args)?;
    let text = String::from_utf8(raw).map_err(|_| "input is not UTF-8 text")?;
    let blob_b64 = text
        .trim()
        .strip_prefix(TRANSPORT_PREFIX)
        .ok_or("input does not start with the WAPQ1: transport prefix")?;
    let env = B64
        .decode(blob_b64.trim())
        .map_err(|e| format!("bad base64 envelope: {e}"))?;

    let opened = open(&my_kem_sk, &sender_sig_pk, &env)?;
    let max_age = flag(args, "--max-age").and_then(|s| s.parse::<u64>().ok());

    // Freshness window (exit 3 distinguishes replay/stale from other failures).
    if let (Some(age), Some(ts)) = (max_age, opened.ts) {
        let skew = now_unix().abs_diff(ts);
        if skew > age {
            eprintln!("pqenv: rejected: timestamp outside freshness window ({skew}s > {age}s)");
            std::process::exit(3);
        }
    }
    // Replay: msg_id must not have been seen before.
    if let (Some(seen), Some(id)) = (flag(args, "--seen"), opened.msg_id) {
        let ts = opened.ts.unwrap_or_else(now_unix);
        if !seen_check_and_record(&seen, &hex16(&id), ts, max_age)? {
            eprintln!("pqenv: rejected: replay detected (msg_id already seen)");
            std::process::exit(3);
        }
    }

    let pt = Zeroizing::new(opened.plaintext);
    write_output(args, &pt)?;
    Ok(())
}

fn cmd_fingerprint(args: &[String]) -> Result<()> {
    let path = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .cloned()
        .or_else(|| flag(args, "--public"))
        .ok_or("fingerprint requires NAME.public")?;
    let fields = read_keyfile(&path)?;
    let kem_pk = field(&fields, "kem_pk")?;
    let sig_pk = field(&fields, "sig_pk")?;
    println!("{}", fingerprint(&kem_pk, &sig_pk));
    Ok(())
}

fn write_mode(path: &str, data: &[u8], mode: u32) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(path)?;
    f.write_all(data)?;
    Ok(())
}

fn cmd_ratchet_prekey(args: &[String]) -> Result<()> {
    let ident = flag(args, "--identity").ok_or("ratchet-prekey requires --identity ME.secret")?;
    let out = flag(args, "--out").ok_or("ratchet-prekey requires --out NAME")?;
    let ifields = read_keyfile(&ident)?;
    let sig_sk = Zeroizing::new(field(&ifields, "sig_sk")?);
    let (pubb, secb) = ratchet::gen_prekey(&sig_sk)?;
    write_mode(&format!("{out}.prekey"), &pubb, 0o644)?;
    write_mode(&format!("{out}.prekey.secret"), &secb, 0o600)?;
    eprintln!("wrote {out}.prekey (share once) and {out}.prekey.secret (0600, one-time)");
    Ok(())
}

fn cmd_ratchet_init(args: &[String]) -> Result<()> {
    let ident = flag(args, "--identity").ok_or("ratchet-init requires --identity ME.secret")?;
    let peer = flag(args, "--peer").ok_or("ratchet-init requires --peer PEER.public")?;
    let prekey = flag(args, "--prekey").ok_or("ratchet-init requires --prekey PEER.prekey")?;
    let session = flag(args, "--session").ok_or("ratchet-init requires --session OUT.session")?;
    let ifields = read_keyfile(&ident)?;
    let pfields = read_keyfile(&peer)?;
    let my_sig_sk = Zeroizing::new(field(&ifields, "sig_sk")?);
    let peer_sig_pk = field(&pfields, "sig_pk")?;
    let prekey_pub = fs::read(&prekey)?;
    let (sess, token) = ratchet::init(&my_sig_sk, &peer_sig_pk, &prekey_pub)?;
    write_mode(&session, &sess, 0o600)?;
    write_output(args, &token)?;
    eprintln!("wrote {session} (0600); send the init token to the peer");
    Ok(())
}

fn cmd_ratchet_accept(args: &[String]) -> Result<()> {
    let peer = flag(args, "--peer").ok_or("ratchet-accept requires --peer PEER.public")?;
    let psec = flag(args, "--prekey-secret")
        .ok_or("ratchet-accept requires --prekey-secret NAME.prekey.secret")?;
    let initf = flag(args, "--init").ok_or("ratchet-accept requires --init INITFILE")?;
    let session = flag(args, "--session").ok_or("ratchet-accept requires --session OUT.session")?;
    let pfields = read_keyfile(&peer)?;
    let peer_sig_pk = field(&pfields, "sig_pk")?;
    let prekey_secret = Zeroizing::new(fs::read(&psec)?);
    let init_token = fs::read(&initf)?;
    let sess = ratchet::accept(&peer_sig_pk, &prekey_secret, &init_token)?;
    write_mode(&session, &sess, 0o600)?;
    // One-time prekey: consume it so it can never seed a second session.
    fs::remove_file(&psec).ok();
    eprintln!("wrote {session} (0600); consumed (deleted) one-time prekey secret {psec}");
    Ok(())
}

fn cmd_ratchet_send(args: &[String]) -> Result<()> {
    let session = flag(args, "--session").ok_or("ratchet-send requires --session S.session")?;
    let blob = Zeroizing::new(fs::read(&session)?);
    let mut s = ratchet::Session::from_bytes(&blob)?;
    let pt = Zeroizing::new(read_input(args)?);
    let msg = s.encrypt(&pt)?;
    write_mode(&session, &s.to_bytes(), 0o600)?;
    write_output(args, &msg)?;
    Ok(())
}

fn cmd_ratchet_recv(args: &[String]) -> Result<()> {
    let session = flag(args, "--session").ok_or("ratchet-recv requires --session S.session")?;
    let blob = Zeroizing::new(fs::read(&session)?);
    let mut s = ratchet::Session::from_bytes(&blob)?;
    let msg = read_input(args)?;
    match s.decrypt(&msg) {
        Ok(pt) => {
            let pt = Zeroizing::new(pt);
            // Persist the advanced session only on success.
            write_mode(&session, &s.to_bytes(), 0o600)?;
            write_output(args, &pt)?;
            Ok(())
        }
        Err(e) => {
            eprintln!("pqenv: rejected: {e}");
            std::process::exit(3);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    let rest: &[String] = if args.len() > 2 { &args[2..] } else { &[] };
    let result = match cmd {
        "keygen" => cmd_keygen(rest),
        "seal" => cmd_seal(rest),
        "open" => cmd_open(rest),
        "fingerprint" => cmd_fingerprint(rest),
        "ratchet-prekey" => cmd_ratchet_prekey(rest),
        "ratchet-init" => cmd_ratchet_init(rest),
        "ratchet-accept" => cmd_ratchet_accept(rest),
        "ratchet-send" => cmd_ratchet_send(rest),
        "ratchet-recv" => cmd_ratchet_recv(rest),
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            return;
        }
        _ => {
            eprint!("{USAGE}");
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("pqenv: {e}");
        std::process::exit(1);
    }
}

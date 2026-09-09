// SPDX-License-Identifier: AGPL-3.0-only
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Dir(PathBuf);
impl Dir {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "pqenv-cli-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_pqenv"))
            .current_dir(&self.0)
            .args(args)
            .output()
            .unwrap()
    }
    fn ok(&self, args: &[&str]) -> Output {
        let result = self.run(args);
        assert!(
            result.status.success(),
            "{:?}: {}",
            args,
            String::from_utf8_lossy(&result.stderr)
        );
        result
    }
    fn identities(&self) {
        self.ok(&["keygen", "--out", "alice"]);
        self.ok(&["keygen", "--out", "bob"]);
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn identity_generation_refuses_overwriting_either_key() {
    let d = Dir::new();
    d.identities();
    let secret = fs::read(d.0.join("alice.secret")).unwrap();
    let public = fs::read(d.0.join("alice.public")).unwrap();
    assert!(!d.run(&["keygen", "--out", "alice"]).status.success());
    assert_eq!(secret, fs::read(d.0.join("alice.secret")).unwrap());
    assert_eq!(public, fs::read(d.0.join("alice.public")).unwrap());
    fs::remove_file(d.0.join("alice.public")).unwrap();
    assert!(!d.run(&["keygen", "--out", "alice"]).status.success());
    assert!(!d.0.join("alice.public").exists());
}

#[test]
fn envelope_outputs_stay_private_and_replay_store_fails_closed() {
    let d = Dir::new();
    d.identities();
    fs::write(d.0.join("input"), b"private message").unwrap();
    fs::write(d.0.join("output"), b"pre-created Emacs temporary").unwrap();
    fs::set_permissions(d.0.join("output"), fs::Permissions::from_mode(0o644)).unwrap();
    d.ok(&[
        "seal",
        "--recipient",
        "bob.public",
        "--identity",
        "alice.secret",
        "--in",
        "input",
        "--out",
        "message",
    ]);
    let args = [
        "open",
        "--identity",
        "bob.secret",
        "--sender",
        "alice.public",
        "--in",
        "message",
        "--out",
        "output",
        "--seen",
        "seen",
        "--max-age",
        "300",
    ];
    fs::write(d.0.join("seen"), b"invalid replay database").unwrap();
    assert!(!d.run(&args).status.success());
    assert_eq!(
        fs::read(d.0.join("output")).unwrap(),
        b"pre-created Emacs temporary"
    );
    fs::remove_file(d.0.join("seen")).unwrap();
    d.ok(&args);
    assert_eq!(fs::read(d.0.join("output")).unwrap(), b"private message");
    assert_eq!(
        fs::metadata(d.0.join("output"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(d.run(&args).status.code(), Some(3));
    assert_eq!(
        d.run(&[
            "open",
            "--identity",
            "bob.secret",
            "--sender",
            "alice.public",
            "--in",
            "message",
            "--max-age",
            "oops"
        ])
        .status
        .code(),
        Some(1)
    );
}

#[test]
fn ratchet_roundtrip_locks_replay_and_consumed_prekey() {
    let d = Dir::new();
    d.identities();
    d.ok(&["ratchet-prekey", "--identity", "bob.secret", "--out", "pre"]);
    let prekey = fs::read(d.0.join("pre.prekey.secret")).unwrap();
    d.ok(&[
        "ratchet-init",
        "--identity",
        "alice.secret",
        "--peer",
        "bob.public",
        "--prekey",
        "pre.prekey",
        "--session",
        "alice.session",
        "--out",
        "init",
    ]);
    let accept = [
        "ratchet-accept",
        "--peer",
        "alice.public",
        "--prekey-secret",
        "pre.prekey.secret",
        "--init",
        "init",
        "--session",
        "bob.session",
    ];
    d.ok(&accept);
    assert!(!d.0.join("pre.prekey.secret").exists());
    assert!(d.0.join("pre.prekey.secret.consumed").exists());
    // Even a stale secret left by a crash cannot be reused with the tombstone.
    fs::write(d.0.join("pre.prekey.secret"), prekey).unwrap();
    let mut replay = accept;
    replay[8] = "another.session";
    assert!(!d.run(&replay).status.success());
    assert!(!d.0.join("another.session").exists());
    fs::write(d.0.join("input"), b"ratchet message").unwrap();
    let lock = fs::File::options()
        .read(true)
        .write(true)
        .create_new(true)
        .open(d.0.join("alice.session.lock"))
        .unwrap();
    lock.try_lock().unwrap();
    let send = [
        "ratchet-send",
        "--session",
        "alice.session",
        "--in",
        "input",
        "--out",
        "message",
    ];
    assert!(!d.run(&send).status.success());
    drop(lock);
    d.ok(&send);
    assert!(!d
        .run(&[
            "ratchet-send",
            "--session",
            "alice.session",
            "--in",
            "input",
            "--out",
            "./alice.session"
        ])
        .status
        .success());
    let receive = [
        "ratchet-recv",
        "--session",
        "bob.session",
        "--in",
        "message",
    ];
    assert_eq!(d.ok(&receive).stdout, b"ratchet message");
    assert_eq!(d.run(&receive).status.code(), Some(3));
}

// SPDX-License-Identifier: AGPL-3.0-only
//! Unix filesystem operations for secret-bearing CLI state.
//!
//! Store state in a private directory on a local filesystem. Locks coordinate
//! pqenv processes; they cannot protect against an attacker controlling the
//! directory, a backup rollback, or callers using an older unlocked binary.
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use pqenv::Result;

pub const MAX_INPUT: u64 = 32 * 1024 * 1024;

pub fn read_limited(reader: impl Read) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take(MAX_INPUT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INPUT {
        return Err("input exceeds the 32 MiB CLI limit".into());
    }
    Ok(bytes)
}

pub fn read(path: &str) -> Result<Vec<u8>> {
    read_limited(File::open(path)?)
}

fn parent(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
}

pub fn resolved(path: &str) -> Result<PathBuf> {
    let p = Path::new(path);
    let name = p.file_name().ok_or("path must name a file")?;
    Ok(parent(p).canonicalize()?.join(name))
}

pub fn sync_parent(path: &str) -> Result<()> {
    File::open(parent(Path::new(path)))?.sync_all()?;
    Ok(())
}

pub fn require_regular(path: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_file() && m.nlink() == 1 => Ok(()),
        Ok(_) => Err(format!("{path}: state must be a regular file with one hard link").into()),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

/// Keep the returned file alive throughout the read/modify/write transaction.
/// The persistent lock inode must never be deleted while pqenv may be running.
pub fn lock(path: &str) -> Result<File> {
    require_regular(path)?;
    let lock_path = format!("{path}.lock");
    let f = match OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&lock_path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {
            require_regular(&lock_path)?;
            let before = fs::symlink_metadata(&lock_path)?;
            let f = OpenOptions::new().read(true).write(true).open(&lock_path)?;
            let after = f.metadata()?;
            if before.dev() != after.dev() || before.ino() != after.ino() {
                return Err("lock file changed while opening it".into());
            }
            f
        }
        Err(e) => return Err(e.into()),
    };
    f.try_lock()
        .map_err(|e| format!("{path}: state is busy or cannot be locked: {e}"))?;
    f.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(f)
}

/// Create a new output. Existing files and symlinks are deliberately refused.
pub fn write_new(path: &str, data: &[u8], mode: u32) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)?;
    f.write_all(data)?;
    f.sync_all()?;
    sync_parent(path)
}

struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Replace a complete state using an exclusive random temporary in its directory.
/// Callers must hold the state lock before reading and until this returns.
pub fn replace(path: &str, data: &[u8]) -> Result<()> {
    require_regular(path)?;
    let mut random = [0u8; 16];
    getrandom::getrandom(&mut random).map_err(|e| format!("getrandom: {e}"))?;
    let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let tmp = Temporary(parent(Path::new(path)).join(format!(".pqenv-{suffix}.tmp")));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp.0)?;
    f.write_all(data)?;
    f.sync_all()?;
    fs::rename(&tmp.0, path)?;
    sync_parent(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    struct Dir(PathBuf);
    impl Dir {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "pqenv-storage-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&p).unwrap();
            Self(p)
        }
        fn file(&self, n: &str) -> String {
            self.0.join(n).to_str().unwrap().to_owned()
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn output_refuses_overwrite_and_symlink() {
        let d = Dir::new();
        let p = d.file("secret");
        let link = d.file("link");
        write_new(&p, b"old", 0o600).unwrap();
        symlink(&p, &link).unwrap();
        assert!(write_new(&p, b"new", 0o600).is_err());
        assert!(write_new(&link, b"new", 0o600).is_err());
        assert!(replace(&link, b"new").is_err());
        assert_eq!(fs::read(p).unwrap(), b"old");
    }
    #[test]
    fn lock_serializes_and_survives_state_replacement() {
        let d = Dir::new();
        let p = d.file("session");
        write_new(&p, b"old", 0o644).unwrap();
        let guard = lock(&p).unwrap();
        assert!(lock(&p).is_err());
        replace(&p, b"advanced").unwrap();
        assert!(lock(&p).is_err());
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(guard);
        assert!(lock(&p).is_ok());
        assert_eq!(fs::read(p).unwrap(), b"advanced");
    }
    #[test]
    fn hardlinked_state_and_symlink_lock_are_refused() {
        let d = Dir::new();
        let p = d.file("session");
        let alias = d.file("alias");
        write_new(&p, b"state", 0o600).unwrap();
        fs::hard_link(&p, &alias).unwrap();
        assert!(lock(&p).is_err());
        fs::remove_file(alias).unwrap();
        symlink(&p, format!("{p}.lock")).unwrap();
        assert!(lock(&p).is_err());
    }
    #[test]
    fn oversized_input_is_rejected() {
        assert!(read_limited(std::io::repeat(0).take(MAX_INPUT + 1)).is_err());
    }
}

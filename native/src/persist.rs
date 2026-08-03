use std::path::PathBuf;

use sha2::{Digest, Sha256};

use crate::core::{MarkRepository, ReadingStateRepository, RecentsRepository};

pub fn lattice_data_dir() -> PathBuf {
    dirs::data_dir()
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Lattice")
}

pub fn mark_repository() -> MarkRepository {
    let dir = lattice_data_dir();
    MarkRepository::new(dir.join("marks-v1.json"), Some(dir.join("portals-v1.json")))
}

pub fn reading_state_repository() -> ReadingStateRepository {
    ReadingStateRepository::new(lattice_data_dir().join("reading-state-v1.json"))
}

pub fn recents_repository() -> RecentsRepository {
    RecentsRepository::new(lattice_data_dir().join("recents-v1.json"), 24)
}

pub fn fingerprint_file(path: &std::path::Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("Could not fingerprint PDF: {e}"))?;
    let digest = Sha256::digest(&bytes);
    Ok(format!("{digest:x}"))
}

pub fn pending_fingerprint(path: &std::path::Path) -> String {
    format!("pending:{}", path.display())
}

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::{JumpLocation, ReadingPosition};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RecentDocument {
    pub fingerprint: String,
    pub path: String,
    pub name: String,
    pub page_count: usize,
    pub last_opened_at: f64,
}

impl RecentDocument {
    pub fn new(
        fingerprint: impl Into<String>,
        path: impl Into<String>,
        name: impl Into<String>,
        page_count: usize,
    ) -> Self {
        let last_opened_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| (d.as_secs_f64() * 1000.0).floor() / 1000.0)
            .unwrap_or(0.0);
        Self {
            fingerprint: fingerprint.into(),
            path: path.into(),
            name: name.into(),
            page_count,
            last_opened_at,
        }
    }

    pub fn exists(&self) -> bool {
        Path::new(&self.path).exists()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RecentsFile {
    schema_version: i32,
    recents: Vec<RecentDocument>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecentsError {
    UnsupportedSchema(i32),
    CorruptFile,
    Io(String),
}

pub struct RecentsRepository {
    pub file_path: PathBuf,
    pub capacity: usize,
}

impl RecentsRepository {
    pub fn new(file_path: PathBuf, capacity: usize) -> Self {
        Self {
            file_path,
            capacity: capacity.max(1),
        }
    }

    pub fn load(&self) -> Result<Vec<RecentDocument>, RecentsError> {
        if !self.file_path.exists() {
            return Ok(Vec::new());
        }
        let data = fs::read(&self.file_path).map_err(|e| RecentsError::Io(e.to_string()))?;
        match serde_json::from_slice::<RecentsFile>(&data) {
            Ok(file) => {
                if file.schema_version != 1 {
                    return Err(RecentsError::UnsupportedSchema(file.schema_version));
                }
                Ok(file.recents.into_iter().filter(|r| r.exists()).collect())
            }
            Err(_) => {
                let backup = self.file_path.with_file_name(format!(
                    "recents-corrupt-{}.json",
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0)
                ));
                let _ = fs::rename(&self.file_path, backup);
                Err(RecentsError::CorruptFile)
            }
        }
    }

    pub fn save(&self, recents: &[RecentDocument]) -> Result<(), RecentsError> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).map_err(|e| RecentsError::Io(e.to_string()))?;
        }
        let trimmed: Vec<_> = recents
            .iter()
            .filter(|r| r.exists())
            .take(self.capacity)
            .cloned()
            .collect();
        let file = RecentsFile {
            schema_version: 1,
            recents: trimmed,
        };
        let data =
            serde_json::to_vec_pretty(&file).map_err(|e| RecentsError::Io(e.to_string()))?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, data).map_err(|e| RecentsError::Io(e.to_string()))?;
        fs::rename(&tmp, &self.file_path).map_err(|e| RecentsError::Io(e.to_string()))?;
        Ok(())
    }

    pub fn record(
        &self,
        document: RecentDocument,
        recents: &mut Vec<RecentDocument>,
    ) -> Result<(), RecentsError> {
        recents.retain(|r| r.fingerprint != document.fingerprint && r.path != document.path);
        recents.insert(0, document);
        self.save(recents)
    }
}

pub fn seeded_recents(
    positions: &std::collections::HashMap<String, ReadingPosition>,
    capacity: usize,
) -> Vec<RecentDocument> {
    let mut values: Vec<_> = positions.values().cloned().collect();
    values.sort_by(|a, b| {
        b.updated_at
            .partial_cmp(&a.updated_at)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut out = Vec::new();
    for position in values {
        let path = position.location.document_path.clone();
        if !Path::new(&path).exists() {
            continue;
        }
        let name = Path::new(&path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("PDF")
            .to_owned();
        let recent = RecentDocument {
            fingerprint: position.location.document_fingerprint.clone(),
            path,
            name,
            page_count: position.location.page_index.saturating_add(1).max(1),
            last_opened_at: position.updated_at,
        };
        if out.iter().any(|r: &RecentDocument| {
            r.fingerprint == recent.fingerprint || r.path == recent.path
        }) {
            continue;
        }
        out.push(recent);
        if out.len() >= capacity {
            break;
        }
    }
    let _ = JumpLocation::home();
    out
}

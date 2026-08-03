use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::JumpLocation;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReadingPosition {
    pub location: SerializedJumpLocation,
    pub updated_at: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SerializedJumpLocation {
    pub document_fingerprint: String,
    pub document_path: String,
    pub page_index: usize,
    pub viewport_center: SerializedPoint,
    pub scale_factor: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SerializedPoint {
    pub x: f64,
    pub y: f64,
}

impl From<&JumpLocation> for SerializedJumpLocation {
    fn from(value: &JumpLocation) -> Self {
        Self {
            document_fingerprint: value.document_fingerprint.clone(),
            document_path: value.document_path.clone(),
            page_index: value.page_index,
            viewport_center: SerializedPoint {
                x: value.viewport_center.x,
                y: value.viewport_center.y,
            },
            scale_factor: value.scale_factor,
        }
    }
}

impl From<&SerializedJumpLocation> for JumpLocation {
    fn from(value: &SerializedJumpLocation) -> Self {
        JumpLocation::new(
            value.document_fingerprint.clone(),
            value.document_path.clone(),
            value.page_index,
            super::NormalizedPoint::new(value.viewport_center.x, value.viewport_center.y),
            value.scale_factor,
        )
    }
}

impl ReadingPosition {
    pub fn new(location: &JumpLocation) -> Self {
        let updated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| (d.as_secs_f64() * 1000.0).floor() / 1000.0)
            .unwrap_or(0.0);
        Self {
            location: location.into(),
            updated_at,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ReadingStateFile {
    schema_version: i32,
    positions: HashMap<String, ReadingPosition>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadingStateError {
    UnsupportedSchema(i32),
    CorruptFile,
    Io(String),
}

pub struct ReadingStateRepository {
    pub file_path: PathBuf,
}

impl ReadingStateRepository {
    pub fn new(file_path: PathBuf) -> Self {
        Self { file_path }
    }

    pub fn load(&self) -> Result<HashMap<String, ReadingPosition>, ReadingStateError> {
        if !self.file_path.exists() {
            return Ok(HashMap::new());
        }
        let data = fs::read(&self.file_path).map_err(|e| ReadingStateError::Io(e.to_string()))?;
        match serde_json::from_slice::<ReadingStateFile>(&data) {
            Ok(file) => {
                if file.schema_version != 1 {
                    return Err(ReadingStateError::UnsupportedSchema(file.schema_version));
                }
                Ok(file.positions)
            }
            Err(_) => {
                let backup = self.file_path.with_file_name(format!(
                    "reading-state-corrupt-{}.json",
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0)
                ));
                let _ = fs::rename(&self.file_path, backup);
                Err(ReadingStateError::CorruptFile)
            }
        }
    }

    pub fn save(&self, positions: &HashMap<String, ReadingPosition>) -> Result<(), ReadingStateError> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).map_err(|e| ReadingStateError::Io(e.to_string()))?;
        }
        let file = ReadingStateFile {
            schema_version: 1,
            positions: positions.clone(),
        };
        let data =
            serde_json::to_vec_pretty(&file).map_err(|e| ReadingStateError::Io(e.to_string()))?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, data).map_err(|e| ReadingStateError::Io(e.to_string()))?;
        fs::rename(&tmp, &self.file_path).map_err(|e| ReadingStateError::Io(e.to_string()))?;
        Ok(())
    }
}

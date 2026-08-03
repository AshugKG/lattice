use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct NormalizedPoint {
    pub x: f64,
    pub y: f64,
}

impl NormalizedPoint {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn clamp(self) -> Self {
        Self {
            x: if self.x.is_finite() {
                self.x.clamp(0.0, 1.0)
            } else {
                0.5
            },
            y: if self.y.is_finite() {
                self.y.clamp(0.0, 1.0)
            } else {
                0.5
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct NormalizedRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl NormalizedRect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn is_valid(self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
            && self.width > 0.0
            && self.height > 0.0
            && self.x >= 0.0
            && self.y >= 0.0
            && self.x + self.width <= 1.000_001
            && self.y + self.height <= 1.000_001
    }

    pub fn center(self) -> NormalizedPoint {
        NormalizedPoint::new(self.x + self.width * 0.5, self.y + self.height * 0.5)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum MarkEndpoint {
    Source,
    Destination,
}

impl MarkEndpoint {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Destination => "destination",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MarkAnchor {
    pub id: Uuid,
    pub document_fingerprint: String,
    pub document_path: String,
    pub page_index: usize,
    pub bounds: NormalizedRect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quoted_text: Option<String>,
}

impl MarkAnchor {
    pub fn new(
        document_fingerprint: impl Into<String>,
        document_path: impl Into<String>,
        page_index: usize,
        bounds: NormalizedRect,
        quoted_text: Option<String>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            document_fingerprint: document_fingerprint.into(),
            document_path: document_path.into(),
            page_index,
            bounds,
            quoted_text,
        }
    }

    pub fn replacing_document_path(&self, path: impl Into<String>) -> Self {
        let mut clone = self.clone();
        clone.document_path = path.into();
        clone
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Mark {
    pub id: Uuid,
    pub source: MarkAnchor,
    pub destination: MarkAnchor,
    /// Seconds since UNIX epoch (macOS Lattice uses secondsSince1970).
    pub created_at: f64,
}

impl Mark {
    pub fn new(source: MarkAnchor, destination: MarkAnchor) -> Self {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| (d.as_secs_f64() * 1000.0).floor() / 1000.0)
            .unwrap_or(0.0);
        Self {
            id: Uuid::new_v4(),
            source,
            destination,
            created_at: now,
        }
    }

    pub fn replacing_document_path(&self, fingerprint: &str, path: &str) -> Self {
        Self {
            id: self.id,
            source: if self.source.document_fingerprint == fingerprint {
                self.source.replacing_document_path(path)
            } else {
                self.source.clone()
            },
            destination: if self.destination.document_fingerprint == fingerprint {
                self.destination.replacing_document_path(path)
            } else {
                self.destination.clone()
            },
            created_at: self.created_at,
        }
    }

    pub fn anchor(&self, endpoint: MarkEndpoint) -> &MarkAnchor {
        match endpoint {
            MarkEndpoint::Source => &self.source,
            MarkEndpoint::Destination => &self.destination,
        }
    }

    pub fn opposite_anchor(&self, endpoint: MarkEndpoint) -> &MarkAnchor {
        match endpoint {
            MarkEndpoint::Source => &self.destination,
            MarkEndpoint::Destination => &self.source,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MarkFile {
    pub schema_version: i32,
    pub marks: Vec<Mark>,
}

impl MarkFile {
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;

    pub fn new(marks: Vec<Mark>) -> Self {
        Self {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            marks,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MarkListEntry {
    pub mark_id: Uuid,
    pub endpoint: MarkEndpoint,
    pub anchor: MarkAnchor,
    pub counterpart: MarkAnchor,
    pub created_at: f64,
}

impl MarkListEntry {
    #[allow(dead_code)]
    pub fn id(&self) -> String {
        format!("{}-{}", self.mark_id, self.endpoint.as_str())
    }
}

pub fn marks_index_entries(fingerprint: &str, marks: &[Mark]) -> Vec<MarkListEntry> {
    let mut entries: Vec<_> = marks
        .iter()
        .filter(|mark| mark.source.document_fingerprint == fingerprint)
        .map(|mark| MarkListEntry {
            mark_id: mark.id,
            endpoint: MarkEndpoint::Source,
            anchor: mark.source.clone(),
            counterpart: mark.destination.clone(),
            created_at: mark.created_at,
        })
        .collect();
    entries.sort_by(|a, b| {
        a.anchor
            .page_index
            .cmp(&b.anchor.page_index)
            .then(
                a.anchor
                    .bounds
                    .y
                    .partial_cmp(&b.anchor.bounds.y)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
            .then(a.endpoint.as_str().cmp(b.endpoint.as_str()))
            .then(
                a.created_at
                    .partial_cmp(&b.created_at)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
    });
    entries
}

pub struct MarkGeometry;

impl MarkGeometry {
    pub fn normalized(rect: [f32; 4], page_bounds: [f32; 4]) -> Option<NormalizedRect> {
        let [rx, ry, rw, rh] = rect;
        let [px, py, pw, ph] = page_bounds;
        if pw <= 0.0 || ph <= 0.0 || rw <= 0.0 || rh <= 0.0 {
            return None;
        }
        let x = ((rx - px) / pw) as f64;
        let y = ((ry - py) / ph) as f64;
        let width = (rw / pw) as f64;
        let height = (rh / ph) as f64;
        let normalized = NormalizedRect::new(
            x.clamp(0.0, 1.0),
            y.clamp(0.0, 1.0),
            width.clamp(0.0, 1.0 - x.clamp(0.0, 1.0)),
            height.clamp(0.0, 1.0 - y.clamp(0.0, 1.0)),
        );
        normalized.is_valid().then_some(normalized)
    }

    pub fn page_rect(normalized: NormalizedRect, page_bounds: [f32; 4]) -> Option<[f32; 4]> {
        if !normalized.is_valid() {
            return None;
        }
        let [px, py, pw, ph] = page_bounds;
        Some([
            px + (normalized.x as f32) * pw,
            py + (normalized.y as f32) * ph,
            (normalized.width as f32) * pw,
            (normalized.height as f32) * ph,
        ])
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkRepositoryError {
    UnsupportedSchema(i32),
    CorruptFile,
    Io(String),
}

pub struct MarkRepository {
    pub file_path: PathBuf,
    legacy_file_path: Option<PathBuf>,
}

impl MarkRepository {
    pub fn new(file_path: PathBuf, legacy_file_path: Option<PathBuf>) -> Self {
        Self {
            file_path,
            legacy_file_path,
        }
    }

    pub fn load(&self) -> Result<Vec<Mark>, MarkRepositoryError> {
        if self.file_path.exists() {
            return self.decode_marks(&self.file_path, false);
        }
        if let Some(legacy) = &self.legacy_file_path
            && legacy.exists()
        {
            let marks = self.decode_marks(legacy, true)?;
            self.save(&marks)?;
            let _ = fs::remove_file(legacy);
            return Ok(marks);
        }
        Ok(Vec::new())
    }

    fn decode_marks(&self, path: &Path, legacy: bool) -> Result<Vec<Mark>, MarkRepositoryError> {
        let data = fs::read(path).map_err(|e| MarkRepositoryError::Io(e.to_string()))?;
        let result = if legacy {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct LegacyMarkFile {
                schema_version: i32,
                #[serde(rename = "portals")]
                marks: Vec<Mark>,
            }
            serde_json::from_slice::<LegacyMarkFile>(&data).map(|file| {
                (
                    file.schema_version,
                    file.marks,
                )
            })
        } else {
            serde_json::from_slice::<MarkFile>(&data)
                .map(|file| (file.schema_version, file.marks))
        };
        match result {
            Ok((schema_version, marks)) => {
                if schema_version != MarkFile::CURRENT_SCHEMA_VERSION {
                    return Err(MarkRepositoryError::UnsupportedSchema(schema_version));
                }
                Ok(marks)
            }
            Err(_) => {
                let backup = path.with_file_name(format!(
                    "marks-corrupt-{}.json",
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0)
                ));
                let _ = fs::rename(path, backup);
                Err(MarkRepositoryError::CorruptFile)
            }
        }
    }

    pub fn save(&self, marks: &[Mark]) -> Result<(), MarkRepositoryError> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).map_err(|e| MarkRepositoryError::Io(e.to_string()))?;
        }
        let data = serde_json::to_vec_pretty(&MarkFile::new(marks.to_vec()))
            .map_err(|e| MarkRepositoryError::Io(e.to_string()))?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, data).map_err(|e| MarkRepositoryError::Io(e.to_string()))?;
        fs::rename(&tmp, &self.file_path).map_err(|e| MarkRepositoryError::Io(e.to_string()))?;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PreviewCacheKey {
    pub fingerprint: u64,
    pub page_index: usize,
    pub bounds_bits: (u64, u64, u64, u64),
    pub backing_scale_milli: u32,
    pub appearance: u8,
}

impl PreviewCacheKey {
    pub fn new(
        fingerprint: &str,
        page_index: usize,
        bounds: NormalizedRect,
        backing_scale: f32,
        appearance: &str,
    ) -> Self {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        fingerprint.hash(&mut hasher);
        Self {
            fingerprint: hasher.finish(),
            page_index,
            bounds_bits: (
                bounds.x.to_bits(),
                bounds.y.to_bits(),
                bounds.width.to_bits(),
                bounds.height.to_bits(),
            ),
            // Match macOS PreviewCacheKey quantization (centi-scale).
            backing_scale_milli: (backing_scale * 100.0).round() as u32,
            appearance: if appearance == "dark" { 1 } else { 0 },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_anchor(page: usize, x: f64) -> MarkAnchor {
        MarkAnchor::new(
            "document",
            "/tmp/document.pdf",
            page,
            NormalizedRect::new(x, 0.2, 0.3, 0.1),
            Some("mark snippet".into()),
        )
    }

    #[test]
    fn mark_file_round_trips() {
        let mark = Mark::new(sample_anchor(1, 0.1), sample_anchor(8, 0.5));
        let data = serde_json::to_vec(&MarkFile::new(vec![mark.clone()])).unwrap();
        let decoded: MarkFile = serde_json::from_slice(&data).unwrap();
        assert_eq!(decoded.marks, vec![mark]);
    }

    #[test]
    fn repository_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marks.json");
        let repo = MarkRepository::new(path, None);
        let first = Mark::new(sample_anchor(1, 0.1), sample_anchor(2, 0.1));
        let second = Mark::new(sample_anchor(3, 0.1), sample_anchor(4, 0.1));
        repo.save(&[first.clone(), second.clone()]).unwrap();
        assert_eq!(repo.load().unwrap(), vec![first, second.clone()]);
        repo.save(&[second.clone()]).unwrap();
        assert_eq!(repo.load().unwrap(), vec![second]);
    }

    #[test]
    fn repository_moves_corrupt_aside() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marks.json");
        fs::write(&path, b"not json").unwrap();
        let repo = MarkRepository::new(path.clone(), None);
        assert_eq!(repo.load().unwrap_err(), MarkRepositoryError::CorruptFile);
        assert!(!path.exists());
    }

    #[test]
    fn normalized_rect_validity() {
        assert!(NormalizedRect::new(0.1, 0.2, 0.3, 0.4).is_valid());
        assert!(!NormalizedRect::new(0.9, 0.2, 0.3, 0.4).is_valid());
    }

    #[test]
    fn mark_geometry_handles_crop() {
        let crop = [40.0, 80.0, 600.0, 800.0];
        let page_rect = [100.0, 160.0, 180.0, 240.0];
        let normalized = MarkGeometry::normalized(page_rect, crop).unwrap();
        assert!((normalized.x - 0.1).abs() < 1e-6);
        assert!((normalized.y - 0.1).abs() < 1e-6);
        assert!((normalized.width - 0.3).abs() < 1e-6);
        assert!((normalized.height - 0.3).abs() < 1e-6);
        let back = MarkGeometry::page_rect(normalized, crop).unwrap();
        assert!((back[0] - page_rect[0]).abs() < 0.01);
    }

    #[test]
    fn marks_index_lists_sources() {
        let mark = Mark::new(sample_anchor(1, 0.1), sample_anchor(8, 0.5));
        let entries = marks_index_entries("document", &[mark]);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].endpoint, MarkEndpoint::Source);
    }

    #[test]
    fn preview_cache_key_stable() {
        let rect = NormalizedRect::new(0.1, 0.2, 0.3, 0.4);
        let a = PreviewCacheKey::new("f", 1, rect, 2.0, "dark");
        let b = PreviewCacheKey::new("f", 1, rect, 2.001, "dark");
        assert_eq!(a, b);
    }
}

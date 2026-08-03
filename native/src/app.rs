use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use eframe::egui::{
    self, Align2, Color32, ColorImage, CornerRadius, FontId, Key, Modifiers, Pos2, Rect, Sense,
    Stroke, TextureHandle, Vec2,
};
use uuid::Uuid;

use crate::camera::Camera;
use crate::core::{
    JumpList, JumpLocation, Mark, MarkAnchor, MarkEndpoint, MarkGeometry, MarkListEntry,
    MarkRepository, NormalizedPoint, ReaderCommand, RecentDocument,
    ReadingPosition, ShortcutModifiers, ShortcutResolver, exact_command, marks_index_entries,
    match_commands, seeded_recents,
};
use crate::engine::{
    Engine, EngineEvent, PageInfo, PageLink, SearchHit, TileKey, TileRequest, visible_tiles,
};
use crate::persist::{
    fingerprint_file, mark_repository, pending_fingerprint, reading_state_repository,
    recents_repository,
};

const PAGE_GAP: f32 = 24.0;
const DOCUMENT_MARGIN: f32 = 32.0;
const MAX_CACHED_TILES: usize = 192;
const MIN_MARK_SIZE: f32 = 8.0;
const PREVIEW_DEBOUNCE: Duration = Duration::from_millis(150);
const HOME_CARD_WIDTH: f32 = 168.0;
const HOME_CARD_HEIGHT: f32 = 248.0;
const HOME_THUMB_SIZE: Vec2 = Vec2::new(148.0, 200.0);

#[derive(Clone, Copy, PartialEq, Eq)]
enum MarkCaptureMode {
    Inactive,
    Source,
    Destination,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SplitLayout {
    Single,
    Vertical,
    Horizontal,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SearchUi {
    None,
    Toolbar,
    VimForward,
    VimBackward,
}

struct DocumentView {
    generation: u64,
    path: PathBuf,
    fingerprint: String,
    pages: Vec<PageInfo>,
    page_origins: Vec<Vec2>,
    size: Vec2,
}

impl DocumentView {
    fn new(generation: u64, path: PathBuf, fingerprint: String, pages: Vec<PageInfo>) -> Self {
        let max_width = pages.iter().map(|page| page.width).fold(0.0, f32::max);
        let mut y = DOCUMENT_MARGIN;
        let mut page_origins = Vec::with_capacity(pages.len());
        for page in &pages {
            page_origins.push(Vec2::new(
                DOCUMENT_MARGIN + (max_width - page.width) * 0.5,
                y,
            ));
            y += page.height + PAGE_GAP;
        }
        let height = if pages.is_empty() {
            DOCUMENT_MARGIN * 2.0
        } else {
            y - PAGE_GAP + DOCUMENT_MARGIN
        };
        Self {
            generation,
            path,
            fingerprint,
            pages,
            page_origins,
            size: Vec2::new(max_width + DOCUMENT_MARGIN * 2.0, height),
        }
    }

    fn page_rect(&self, index: usize) -> Rect {
        Rect::from_min_size(self.page_origins[index].to_pos2(), self.pages[index].size())
    }

    fn page_at_document_y(&self, y: f32) -> usize {
        for (index, origin) in self.page_origins.iter().enumerate() {
            let top = origin.y;
            let bottom = top + self.pages[index].height;
            if y >= top && y <= bottom + PAGE_GAP * 0.5 {
                return index;
            }
        }
        self.pages.len().saturating_sub(1)
    }

    fn document_point_for_anchor(&self, anchor: &MarkAnchor) -> Option<Pos2> {
        let page_rect = self.page_rect(anchor.page_index);
        let bounds = [
            page_rect.min.x,
            page_rect.min.y,
            page_rect.width(),
            page_rect.height(),
        ];
        let page = MarkGeometry::page_rect(anchor.bounds, bounds)?;
        Some(Pos2::new(page[0] + page[2] * 0.5, page[1] + page[3] * 0.5))
    }
}

struct CachedTile {
    texture: TextureHandle,
    last_used_frame: u64,
}

struct PaneState {
    document: Option<DocumentView>,
    camera: Camera,
    display_lists: HashMap<usize, Arc<mupdf::DisplayList>>,
    requested_pages: HashSet<usize>,
    tiles: HashMap<TileKey, CachedTile>,
    pending_tiles: HashSet<TileKey>,
    links: HashMap<usize, Vec<PageLink>>,
    viewport: Rect,
}

impl PaneState {
    fn new() -> Self {
        Self {
            document: None,
            camera: Camera::default(),
            display_lists: HashMap::new(),
            requested_pages: HashSet::new(),
            tiles: HashMap::new(),
            pending_tiles: HashSet::new(),
            links: HashMap::new(),
            viewport: Rect::ZERO,
        }
    }

    fn clear_document(&mut self) {
        self.document = None;
        self.camera = Camera::default();
        self.display_lists.clear();
        self.requested_pages.clear();
        self.tiles.clear();
        self.pending_tiles.clear();
        self.links.clear();
    }

    fn jump_location(&self) -> Option<JumpLocation> {
        let document = self.document.as_ref()?;
        let center = self.camera.viewport_center_document(self.viewport);
        let page = document.page_at_document_y(center.y);
        let page_rect = document.page_rect(page);
        let nx = ((center.x - page_rect.min.x) / page_rect.width()).clamp(0.0, 1.0) as f64;
        let ny = ((center.y - page_rect.min.y) / page_rect.height()).clamp(0.0, 1.0) as f64;
        Some(JumpLocation::new(
            document.fingerprint.clone(),
            document.path.display().to_string(),
            page,
            NormalizedPoint::new(nx, ny),
            self.camera.zoom as f64,
        ))
    }

    fn go_to_location(&mut self, location: &JumpLocation) {
        let Some(document) = self.document.as_ref() else {
            return;
        };
        if location.page_index >= document.pages.len() {
            return;
        }
        let page_rect = document.page_rect(location.page_index);
        let point = Pos2::new(
            page_rect.min.x + page_rect.width() * location.viewport_center.x as f32,
            page_rect.min.y + page_rect.height() * location.viewport_center.y as f32,
        );
        let zoom = location.scale_factor as f32;
        let size = document.size;
        let viewport = self.viewport;
        self.camera
            .go_to_point(point, viewport, size, Some(zoom));
    }

    fn go_to_anchor(&mut self, anchor: &MarkAnchor, scale: Option<f32>) {
        let Some(document) = self.document.as_ref() else {
            return;
        };
        let Some(point) = document.document_point_for_anchor(anchor) else {
            return;
        };
        let size = document.size;
        let viewport = self.viewport;
        self.camera.go_to_point(point, viewport, size, scale);
    }
}

struct MarkDraft {
    source: MarkAnchor,
}

struct PendingPreview {
    mark_id: Uuid,
    endpoint: MarkEndpoint,
    since: Instant,
}

struct PreviewState {
    texture: Option<TextureHandle>,
    mark_id: Uuid,
    endpoint: MarkEndpoint,
    request_id: u64,
}

pub struct LatticeApp {
    engine: Engine,
    panes: [PaneState; 2],
    pane_count: usize,
    active_pane: usize,
    split_layout: SplitLayout,
    loading: bool,
    status: String,
    frame_index: u64,
    shortcuts: ShortcutResolver,
    marks: Vec<Mark>,
    mark_repo: MarkRepository,
    mark_mode: MarkCaptureMode,
    mark_draft: Option<MarkDraft>,
    drag_start: Option<(usize, Pos2)>,
    drag_current: Option<Pos2>,
    pending_quoted: Option<(usize, Rect)>,
    control_held: bool,
    pending_preview: Option<PendingPreview>,
    preview: Option<PreviewState>,
    preview_request_id: u64,
    preview_anchor: Option<Rect>,
    jump_list: JumpList,
    reading_positions: HashMap<String, ReadingPosition>,
    recents: Vec<RecentDocument>,
    thumbnails: HashMap<String, TextureHandle>,
    pending_thumbnails: HashSet<String>,
    show_home: bool,
    show_help: bool,
    show_marks_list: bool,
    marks_list_selection: usize,
    show_palette: bool,
    palette_query: String,
    palette_selection: usize,
    search_ui: SearchUi,
    search_query: String,
    search_hits: Vec<SearchHit>,
    search_index: Option<usize>,
    password_prompt: Option<(u64, PathBuf)>,
    password_input: String,
    pending_open_restore: Option<JumpLocation>,
    flash_until: Option<Instant>,
    focus_toolbar_search: bool,
}

impl LatticeApp {
    pub fn new(creation: &eframe::CreationContext<'_>, initial_path: Option<PathBuf>) -> Self {
        let mark_repo = mark_repository();
        let marks = mark_repo.load().unwrap_or_default();
        let reading_positions = reading_state_repository().load().unwrap_or_default();
        let mut recents = recents_repository().load().unwrap_or_default();
        if recents.is_empty() {
            recents = seeded_recents(&reading_positions, 24);
        }
        let engine = Engine::new(creation.egui_ctx.clone());
        let mut app = Self {
            engine,
            panes: [PaneState::new(), PaneState::new()],
            pane_count: 1,
            active_pane: 0,
            split_layout: SplitLayout::Single,
            loading: false,
            status: "Open a PDF to begin".into(),
            frame_index: 0,
            shortcuts: ShortcutResolver::new(),
            marks,
            mark_repo,
            mark_mode: MarkCaptureMode::Inactive,
            mark_draft: None,
            drag_start: None,
            drag_current: None,
            pending_quoted: None,
            control_held: false,
            pending_preview: None,
            preview: None,
            preview_request_id: 0,
            preview_anchor: None,
            jump_list: JumpList::new(100),
            reading_positions,
            recents,
            thumbnails: HashMap::new(),
            pending_thumbnails: HashSet::new(),
            show_home: initial_path.is_none(),
            show_help: false,
            show_marks_list: false,
            marks_list_selection: 0,
            show_palette: false,
            palette_query: String::new(),
            palette_selection: 0,
            search_ui: SearchUi::None,
            search_query: String::new(),
            search_hits: Vec::new(),
            search_index: None,
            password_prompt: None,
            password_input: String::new(),
            pending_open_restore: None,
            flash_until: None,
            focus_toolbar_search: false,
        };
        if let Some(path) = initial_path {
            app.open_path(path, true);
        }
        app
    }

    fn active_pane_mut(&mut self) -> &mut PaneState {
        &mut self.panes[self.active_pane]
    }

    fn active_pane(&self) -> &PaneState {
        &self.panes[self.active_pane]
    }

    fn open_path(&mut self, path: PathBuf, record_jump_from_home: bool) {
        if record_jump_from_home && self.show_home {
            self.jump_list.record_before_jump(JumpLocation::home());
        } else if let Some(current) = self.active_pane().jump_location() {
            self.jump_list.record_before_jump(current);
        }
        self.show_home = false;
        self.loading = true;
        self.status = format!("Opening {}…", path.display());
        self.password_prompt = None;
        self.password_input.clear();
        let pending = pending_fingerprint(&path);
        if let Some(position) = self.reading_positions.get(&pending).cloned().or_else(|| {
            fingerprint_file(&path)
                .ok()
                .and_then(|fp| self.reading_positions.get(&fp).cloned())
        }) {
            self.pending_open_restore = Some((&position.location).into());
        } else {
            self.pending_open_restore = None;
        }
        self.engine.open(path);
    }

    fn pick_open(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("PDF document", &["pdf"])
            .pick_file()
        {
            self.open_path(path, true);
        }
    }

    fn save_marks(&mut self) {
        if let Err(error) = self.mark_repo.save(&self.marks) {
            self.status = format!("Could not save marks: {error:?}");
        }
    }

    fn save_reading_state(&mut self) {
        if let Some(location) = self.active_pane().jump_location() {
            if location.is_home() {
                return;
            }
            self.reading_positions.insert(
                location.document_fingerprint.clone(),
                ReadingPosition::new(&location),
            );
            let _ = reading_state_repository().save(&self.reading_positions);
        }
    }

    fn record_recent(&mut self, document: &DocumentView) {
        let recent = RecentDocument::new(
            document.fingerprint.clone(),
            document.path.display().to_string(),
            document
                .path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("PDF")
                .to_owned(),
            document.pages.len(),
        );
        let _ = recents_repository().record(recent, &mut self.recents);
    }

    fn handle_events(&mut self, ctx: &egui::Context) {
        while let Some(event) = self.engine.try_recv() {
            match event {
                EngineEvent::PasswordRequired { generation, path } => {
                    self.loading = false;
                    self.password_prompt = Some((generation, path));
                    self.status = "Password required".into();
                }
                EngineEvent::Opened {
                    generation,
                    path,
                    pages,
                    fingerprint,
                    ..
                } => {
                    let pending = pending_fingerprint(&path);
                    self.jump_list
                        .rewrite_fingerprint(&pending, &fingerprint, &path.display().to_string());
                    let document = DocumentView::new(generation, path, fingerprint.clone(), pages);
                    self.record_recent(&document);
                    let pane = self.active_pane_mut();
                    pane.clear_document();
                    pane.document = Some(document);
                    pane.camera = Camera::default();
                    self.loading = false;
                    self.status.clear();
                    self.show_home = false;
                    if let Some(restore) = self.pending_open_restore.take() {
                        let restore = restore.clamped(
                            self.active_pane()
                                .document
                                .as_ref()
                                .map(|d| d.pages.len())
                                .unwrap_or(0),
                            0.25,
                            8.0,
                        );
                        self.active_pane_mut().go_to_location(&restore);
                    }
                    self.save_reading_state();
                }
                EngineEvent::PageReady {
                    generation,
                    page,
                    display_list,
                } => {
                    for pane in &mut self.panes[..self.pane_count] {
                        if pane
                            .document
                            .as_ref()
                            .is_some_and(|doc| doc.generation == generation)
                        {
                            pane.display_lists.insert(page, display_list.clone());
                            pane.requested_pages.remove(&page);
                            self.engine.request_links(generation, page);
                        }
                    }
                }
                EngineEvent::TileReady { key, image } => {
                    for pane in &mut self.panes[..self.pane_count] {
                        pane.pending_tiles.remove(&key);
                        if pane
                            .document
                            .as_ref()
                            .is_some_and(|doc| doc.generation == key.generation)
                        {
                            let image =
                                ColorImage::from_rgb([image.width, image.height], &image.rgb);
                            let texture = ctx.load_texture(
                                format!("tile-{key:?}"),
                                image,
                                egui::TextureOptions::LINEAR,
                            );
                            pane.tiles.insert(
                                key,
                                CachedTile {
                                    texture,
                                    last_used_frame: self.frame_index,
                                },
                            );
                        }
                    }
                }
                EngineEvent::SearchReady {
                    generation,
                    query,
                    hits,
                } => {
                    if self
                        .active_pane()
                        .document
                        .as_ref()
                        .is_some_and(|doc| doc.generation == generation)
                    {
                        self.search_query = query;
                        self.search_hits = hits;
                        self.search_index = if self.search_hits.is_empty() {
                            None
                        } else {
                            Some(0)
                        };
                        if let Some(0) = self.search_index {
                            self.jump_to_search_hit(0, true);
                        }
                        self.status = if self.search_hits.is_empty() {
                            "No matches".into()
                        } else {
                            format!("{} matches", self.search_hits.len())
                        };
                    }
                }
                EngineEvent::LinksReady {
                    generation,
                    page,
                    links,
                } => {
                    for pane in &mut self.panes[..self.pane_count] {
                        if pane
                            .document
                            .as_ref()
                            .is_some_and(|doc| doc.generation == generation)
                        {
                            pane.links.insert(page, links.clone());
                        }
                    }
                }
                EngineEvent::TextReady {
                    generation,
                    page,
                    rect: _,
                    text,
                } => {
                    if self
                        .pending_quoted
                        .as_ref()
                        .is_some_and(|(p, _)| *p == page)
                        && self
                            .active_pane()
                            .document
                            .as_ref()
                            .is_some_and(|doc| doc.generation == generation)
                    {
                        self.pending_quoted = None;
                        let quote = if text.trim().is_empty() {
                            None
                        } else {
                            Some(text)
                        };
                        if let Some(draft) = &mut self.mark_draft
                            && draft.source.quoted_text.is_none()
                        {
                            draft.source.quoted_text = quote;
                        } else if let Some(mark) = self.marks.last_mut() {
                            if mark.destination.quoted_text.is_none() {
                                mark.destination.quoted_text = quote;
                            } else if mark.source.quoted_text.is_none() {
                                mark.source.quoted_text = quote;
                            }
                            self.save_marks();
                        }
                    }
                }
                EngineEvent::CropReady {
                    generation,
                    page: _,
                    rect: _,
                    image,
                    request_id,
                } => {
                    if self
                        .preview
                        .as_ref()
                        .is_some_and(|p| p.request_id == request_id)
                        && self
                            .active_pane()
                            .document
                            .as_ref()
                            .is_some_and(|doc| doc.generation == generation)
                    {
                        let color =
                            ColorImage::from_rgb([image.width, image.height], &image.rgb);
                        let texture = ctx.load_texture(
                            format!("preview-{request_id}"),
                            color,
                            egui::TextureOptions::LINEAR,
                        );
                        if let Some(preview) = &mut self.preview {
                            preview.texture = Some(texture);
                        }
                    }
                }
                EngineEvent::ThumbnailReady { fingerprint, image } => {
                    self.pending_thumbnails.remove(&fingerprint);
                    let color = ColorImage::from_rgb([image.width, image.height], &image.rgb);
                    let texture = ctx.load_texture(
                        format!("thumb-{fingerprint}"),
                        color,
                        egui::TextureOptions::LINEAR,
                    );
                    self.thumbnails.insert(fingerprint, texture);
                }
                EngineEvent::Failed(message) => {
                    self.loading = false;
                    self.status = message;
                }
            }
        }
    }

    fn finish_mark_capture(&mut self, page: usize, document_rect: Rect, quoted: Option<String>) {
        let Some(document) = self.active_pane().document.as_ref() else {
            return;
        };
        let page_rect = document.page_rect(page);
        let Some(bounds) = MarkGeometry::normalized(
            [
                document_rect.min.x,
                document_rect.min.y,
                document_rect.width(),
                document_rect.height(),
            ],
            [
                page_rect.min.x,
                page_rect.min.y,
                page_rect.width(),
                page_rect.height(),
            ],
        ) else {
            self.status = "Mark rectangle too small".into();
            return;
        };
        let anchor = MarkAnchor::new(
            document.fingerprint.clone(),
            document.path.display().to_string(),
            page,
            bounds,
            quoted,
        );
        match self.mark_mode {
            MarkCaptureMode::Source => {
                self.mark_draft = Some(MarkDraft { source: anchor });
                self.mark_mode = MarkCaptureMode::Destination;
                self.status = "Mark source set — navigate and drag destination".into();
            }
            MarkCaptureMode::Destination => {
                if let Some(draft) = self.mark_draft.take() {
                    let mark = Mark::new(draft.source, anchor);
                    self.marks.push(mark);
                    self.save_marks();
                    self.mark_mode = MarkCaptureMode::Inactive;
                    self.status = "Mark created".into();
                }
            }
            MarkCaptureMode::Inactive => {}
        }
    }

    fn capture_drag_as_mark(&mut self) {
        let Some((page, start)) = self.drag_start else {
            return;
        };
        let Some(end) = self.drag_current else {
            return;
        };
        self.drag_start = None;
        self.drag_current = None;
        let rect = Rect::from_two_pos(start, end);
        if rect.width() < MIN_MARK_SIZE || rect.height() < MIN_MARK_SIZE {
            self.status = "Drag a larger rectangle".into();
            return;
        }
        let Some(document) = self.active_pane().document.as_ref() else {
            return;
        };
        let page_rect = document.page_rect(page);
        let clipped = rect.intersect(page_rect);
        if clipped.width() < MIN_MARK_SIZE || clipped.height() < MIN_MARK_SIZE {
            self.status = "Drag a larger rectangle".into();
            return;
        }
        let generation = document.generation;
        let page_local = clipped.translate(-page_rect.min.to_vec2());
        self.pending_quoted = Some((page, clipped));
        self.engine
            .text_under_rect(generation, page, page_local);
        self.finish_mark_capture(page, clipped, None);
    }

    fn begin_mark_capture(&mut self) {
        self.mark_mode = MarkCaptureMode::Source;
        self.mark_draft = None;
        self.status = "Drag to capture mark source".into();
    }

    fn cancel_mark(&mut self) {
        if self.mark_mode != MarkCaptureMode::Inactive {
            self.mark_mode = MarkCaptureMode::Inactive;
            self.mark_draft = None;
            self.drag_start = None;
            self.drag_current = None;
            self.status = "Mark capture cancelled".into();
            return;
        }
        self.search_ui = SearchUi::None;
        self.search_hits.clear();
        self.search_index = None;
        self.show_palette = false;
        self.show_marks_list = false;
        self.show_help = false;
    }

    fn marks_for_document(&self, fingerprint: &str) -> Vec<&Mark> {
        self.marks
            .iter()
            .filter(|mark| {
                mark.source.document_fingerprint == fingerprint
                    || mark.destination.document_fingerprint == fingerprint
            })
            .collect()
    }

    fn activate_mark(&mut self, mark_id: Uuid, endpoint: MarkEndpoint) {
        let Some(mark) = self.marks.iter().find(|m| m.id == mark_id).cloned() else {
            return;
        };
        let target = mark.opposite_anchor(endpoint).clone();
        if let Some(current) = self.active_pane().jump_location() {
            self.jump_list.record_before_jump(current);
        }
        let same_doc = self
            .active_pane()
            .document
            .as_ref()
            .is_some_and(|doc| doc.fingerprint == target.document_fingerprint);
        if same_doc {
            self.active_pane_mut().go_to_anchor(&target, None);
            self.flash_until = Some(Instant::now() + Duration::from_millis(450));
            self.save_reading_state();
            return;
        }
        let path = PathBuf::from(&target.document_path);
        if path.exists() {
            match fingerprint_file(&path) {
                Ok(fp) if fp == target.document_fingerprint => {
                    self.pending_open_restore = Some(JumpLocation::new(
                        target.document_fingerprint.clone(),
                        target.document_path.clone(),
                        target.page_index,
                        target.bounds.center(),
                        self.active_pane().camera.zoom as f64,
                    ));
                    self.open_path(path, false);
                    return;
                }
                Ok(_) => {
                    // Path moved / replaced — try locate by scanning marks path only
                    self.status = "Mark document fingerprint mismatch".into();
                }
                Err(error) => self.status = error,
            }
        }
        // Path recovery: rewrite if user opens matching fingerprint later; try rfd locate
        if let Some(found) = rfd::FileDialog::new()
            .set_title("Locate marked PDF")
            .add_filter("PDF document", &["pdf"])
            .pick_file()
        {
            if let Ok(fp) = fingerprint_file(&found)
                && fp == target.document_fingerprint
            {
                let path_str = found.display().to_string();
                self.marks = self
                    .marks
                    .iter()
                    .map(|m| m.replacing_document_path(&fp, &path_str))
                    .collect();
                self.save_marks();
                self.pending_open_restore = Some(JumpLocation::new(
                    target.document_fingerprint,
                    path_str,
                    target.page_index,
                    target.bounds.center(),
                    self.active_pane().camera.zoom as f64,
                ));
                self.open_path(found, false);
                return;
            }
            self.status = "Selected file does not match mark fingerprint".into();
        }
    }

    fn delete_mark(&mut self, mark_id: Uuid) {
        self.marks.retain(|mark| mark.id != mark_id);
        self.save_marks();
        self.status = "Mark deleted".into();
    }

    fn jump_to_search_hit(&mut self, index: usize, record: bool) {
        let Some(hit) = self.search_hits.get(index).cloned() else {
            return;
        };
        if record && let Some(current) = self.active_pane().jump_location() {
            self.jump_list.record_before_jump(current);
        }
        let Some(document) = self.active_pane().document.as_ref() else {
            return;
        };
        if hit.page >= document.pages.len() {
            return;
        }
        let page_rect = document.page_rect(hit.page);
        let point = Pos2::new(
            page_rect.min.x + hit.rect.center().x,
            page_rect.min.y + hit.rect.center().y,
        );
        let size = document.size;
        let viewport = self.active_pane().viewport;
        self.active_pane_mut()
            .camera
            .go_to_point(point, viewport, size, None);
        self.search_index = Some(index);
    }

    fn run_search(&mut self) {
        let query = self.search_query.trim().to_owned();
        if query.is_empty() {
            return;
        }
        let Some(document) = self.active_pane().document.as_ref() else {
            return;
        };
        self.engine.search(document.generation, query);
    }

    fn apply_command(&mut self, command: ReaderCommand, viewport: Rect) {
        match command {
            ReaderCommand::Open => self.pick_open(),
            ReaderCommand::Help => self.show_help = true,
            ReaderCommand::ScrollDown => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_lines(1.0, viewport, size);
            }
            ReaderCommand::ScrollUp => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_lines(-1.0, viewport, size);
            }
            ReaderCommand::ScrollLeft => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_by_screen(Vec2::new(-88.0, 0.0), viewport, size);
            }
            ReaderCommand::ScrollRight => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_by_screen(Vec2::new(88.0, 0.0), viewport, size);
            }
            ReaderCommand::HalfDown => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_half(true, viewport, size);
            }
            ReaderCommand::HalfUp => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .scroll_half(false, viewport, size);
            }
            ReaderCommand::DocumentStart => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .go_to_document_y(0.0, viewport, size);
            }
            ReaderCommand::DocumentEnd => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut().camera.go_to_document_y(
                    size.y,
                    viewport,
                    size,
                );
            }
            ReaderCommand::NextPage | ReaderCommand::PreviousPage => {
                let delta = if matches!(command, ReaderCommand::NextPage) {
                    1isize
                } else {
                    -1
                };
                if let Some(location) = self.active_pane().jump_location() {
                    let page = location.page_index as isize + delta;
                    if page >= 0 {
                        self.go_to_page(page as usize);
                    }
                }
            }
            ReaderCommand::GoToPage(page) => self.go_to_page(page.saturating_sub(1)),
            ReaderCommand::ZoomIn => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .zoom_by(1.1, viewport, size);
            }
            ReaderCommand::ZoomOut => {
                let size = self
                    .active_pane()
                    .document
                    .as_ref()
                    .map(|d| d.size)
                    .unwrap_or(Vec2::ZERO);
                self.active_pane_mut()
                    .camera
                    .zoom_by(1.0 / 1.1, viewport, size);
            }
            ReaderCommand::FitWidth => {
                if let Some(document) = self.active_pane().document.as_ref() {
                    let width = document.size.x;
                    let size = document.size;
                    self.active_pane_mut()
                        .camera
                        .fit_width(viewport, width, size);
                }
            }
            ReaderCommand::FindToolbar => {
                self.search_ui = SearchUi::Toolbar;
                self.focus_toolbar_search = true;
            }
            ReaderCommand::FindForward => {
                self.search_ui = SearchUi::VimForward;
                self.search_query.clear();
            }
            ReaderCommand::FindBackward => {
                self.search_ui = SearchUi::VimBackward;
                self.search_query.clear();
            }
            ReaderCommand::FindNext => {
                if let Some(index) = self.search_index {
                    let next = (index + 1) % self.search_hits.len().max(1);
                    self.jump_to_search_hit(next, true);
                }
            }
            ReaderCommand::FindPrevious => {
                if let Some(index) = self.search_index {
                    let prev = if index == 0 {
                        self.search_hits.len().saturating_sub(1)
                    } else {
                        index - 1
                    };
                    self.jump_to_search_hit(prev, true);
                }
            }
            ReaderCommand::CaptureMark => self.begin_mark_capture(),
            ReaderCommand::CancelMark => self.cancel_mark(),
            ReaderCommand::JumpBackward => self.jump_history(true),
            ReaderCommand::JumpForward => self.jump_history(false),
            ReaderCommand::ShowCommandPalette => {
                self.show_palette = true;
                self.palette_query.clear();
                self.palette_selection = 0;
            }
            ReaderCommand::ShowMarks => {
                self.show_marks_list = true;
                self.marks_list_selection = 0;
            }
            ReaderCommand::ShowHome => self.go_home(),
            ReaderCommand::VerticalSplit => self.split(SplitLayout::Vertical),
            ReaderCommand::HorizontalSplit => self.split(SplitLayout::Horizontal),
            ReaderCommand::CloseSplit => self.close_split(),
            ReaderCommand::FocusLeft | ReaderCommand::FocusUp => {
                if self.pane_count > 1 {
                    self.active_pane = 0;
                }
            }
            ReaderCommand::FocusRight | ReaderCommand::FocusDown => {
                if self.pane_count > 1 {
                    self.active_pane = 1;
                }
            }
            ReaderCommand::Quit => self.go_home_all(),
        }
        self.save_reading_state();
    }

    fn go_to_page(&mut self, page: usize) {
        let page_count = self
            .active_pane()
            .document
            .as_ref()
            .map(|d| d.pages.len())
            .unwrap_or(0);
        if page >= page_count {
            return;
        }
        if let Some(current) = self.active_pane().jump_location() {
            self.jump_list.record_before_jump(current);
        }
        let (page_center, size, viewport) = {
            let pane = self.active_pane();
            let document = pane.document.as_ref().unwrap();
            (document.page_rect(page).center(), document.size, pane.viewport)
        };
        self.active_pane_mut()
            .camera
            .go_to_point(page_center, viewport, size, None);
    }

    fn jump_history(&mut self, backward: bool) {
        let current = if self.show_home {
            Some(JumpLocation::home())
        } else {
            self.active_pane().jump_location()
        };
        let target = if backward {
            self.jump_list.go_backward(current.clone())
        } else {
            self.jump_list.go_forward(current.clone())
        };
        let Some(target) = target else {
            return;
        };
        if target.is_home() {
            self.show_home = true;
            return;
        }
        let same = self
            .active_pane()
            .document
            .as_ref()
            .is_some_and(|doc| doc.fingerprint == target.document_fingerprint);
        if same {
            self.show_home = false;
            self.active_pane_mut().go_to_location(&target);
            return;
        }
        let path = PathBuf::from(&target.document_path);
        if path.exists() {
            self.pending_open_restore = Some(target);
            self.open_path(path, false);
        } else if backward {
            self.jump_list
                .cancel_backward(target, current.as_ref());
            self.status = "Jump target missing".into();
        } else {
            self.jump_list.cancel_forward(target, current.as_ref());
            self.status = "Jump target missing".into();
        }
    }

    fn go_home(&mut self) {
        if let Some(current) = self.active_pane().jump_location() {
            self.jump_list.record_before_jump(current);
            self.save_reading_state();
        }
        self.show_home = true;
        self.active_pane_mut().clear_document();
        self.pane_count = 1;
        self.active_pane = 0;
        self.split_layout = SplitLayout::Single;
        self.panes[1].clear_document();
    }

    fn go_home_all(&mut self) {
        self.go_home();
    }

    fn close_split(&mut self) {
        if self.pane_count > 1 {
            if self.active_pane == 0 {
                self.panes.swap(0, 1);
            }
            self.panes[1].clear_document();
            self.pane_count = 1;
            self.active_pane = 0;
            self.split_layout = SplitLayout::Single;
        } else {
            self.go_home();
        }
    }

    fn split(&mut self, layout: SplitLayout) {
        let snapshot = {
            let pane = self.active_pane();
            (
                pane.document.as_ref().map(|d| {
                    (
                        d.path.clone(),
                        d.fingerprint.clone(),
                        d.pages.clone(),
                        d.generation,
                    )
                }),
                pane.camera.clone(),
                pane.jump_location(),
            )
        };
        let Some((path, fingerprint, pages, generation)) = snapshot.0 else {
            self.status = "Open a PDF before splitting".into();
            return;
        };
        if self.pane_count == 1 {
            self.pane_count = 2;
            let other = 1 - self.active_pane;
            let display_lists = self.panes[self.active_pane].display_lists.clone();
            let other_pane = &mut self.panes[other];
            other_pane.clear_document();
            other_pane.document = Some(DocumentView::new(
                generation,
                path,
                fingerprint,
                pages,
            ));
            other_pane.camera = snapshot.1;
            other_pane.display_lists = display_lists;
            if let Some(location) = snapshot.2 {
                other_pane.go_to_location(&location);
            }
        } else {
            let src = self.active_pane;
            let dst = 1 - src;
            self.panes[dst].camera = self.panes[src].camera.clone();
            if let Some(location) = self.panes[src].jump_location() {
                self.panes[dst].go_to_location(&location);
            }
        }
        self.split_layout = layout;
    }

    fn handle_keys(&mut self, ctx: &egui::Context) {
        if self.password_prompt.is_some()
            || self.show_palette
            || self.show_marks_list
            || matches!(self.search_ui, SearchUi::VimForward | SearchUi::VimBackward)
            || (self.search_ui == SearchUi::Toolbar && self.focus_toolbar_search)
        {
            return;
        }

        self.control_held = ctx.input(|i| i.modifiers.ctrl || i.modifiers.command && cfg!(target_os = "macos") == false);
        // Control for marks: egui Modifiers.ctrl on Windows/Linux; on macOS use ctrl (not cmd)
        self.control_held = ctx.input(|i| i.modifiers.ctrl);

        let events: Vec<_> = ctx.input(|i| {
            i.events
                .iter()
                .filter_map(|event| match event {
                    egui::Event::Key {
                        key,
                        pressed: true,
                        modifiers,
                        ..
                    } => Some((key_name(*key), *modifiers, false)),
                    egui::Event::Text(text) => Some((text.clone(), Modifiers::default(), true)),
                    _ => None,
                })
                .collect()
        });

        let timestamp = ctx.input(|i| i.time);
        let viewport = self.active_pane().viewport;
        for (key, modifiers, is_text) in events {
            if is_text && (modifiers.ctrl || modifiers.command) {
                continue;
            }
            if is_text && key.len() == 1 {
                let ch = key.chars().next().unwrap();
                if let Some(command) = self.shortcuts.resolve(
                    &ch.to_string(),
                    ShortcutModifiers {
                        control: false,
                        command: false,
                    },
                    timestamp,
                ) {
                    self.apply_command(command, viewport);
                }
                continue;
            }
            if !is_text {
                let shortcut_key = match key.as_str() {
                    "Escape" => "\u{1b}".to_owned(),
                    other => other.to_owned(),
                };
                if let Some(command) = self.shortcuts.resolve(
                    &shortcut_key,
                    ShortcutModifiers {
                        control: modifiers.ctrl,
                        command: modifiers.mac_cmd || modifiers.command,
                    },
                    timestamp,
                ) {
                    self.apply_command(command, viewport);
                }
            }
        }
    }

    fn prune_tiles(pane: &mut PaneState, frame_index: u64) {
        if pane.tiles.len() <= MAX_CACHED_TILES {
            return;
        }
        // Prefer keeping tiles touched this frame (including LOD cover tiles).
        let mut oldest: Vec<_> = pane
            .tiles
            .iter()
            .filter(|(_, tile)| tile.last_used_frame != frame_index)
            .map(|(key, tile)| (*key, tile.last_used_frame))
            .collect();
        oldest.sort_unstable_by_key(|(_, frame)| *frame);
        let remove_count = pane.tiles.len() - MAX_CACHED_TILES;
        for (key, _) in oldest.into_iter().take(remove_count) {
            pane.tiles.remove(&key);
        }
    }
}

fn key_name(key: Key) -> String {
    match key {
        Key::Escape => "Escape".into(),
        Key::Equals => "=".into(),
        Key::Minus => "-".into(),
        Key::Num0 => "0".into(),
        Key::OpenBracket => "[".into(),
        Key::CloseBracket => "]".into(),
        other => format!("{other:?}"),
    }
}

/// Find a nearby cached LOD tile that covers `target_page_rect` while the desired LOD loads.
fn find_cover_tile(
    tiles: &HashMap<TileKey, CachedTile>,
    generation: u64,
    page: usize,
    target_page_rect: Rect,
    target_lod: i16,
) -> Option<(TileKey, f32)> {
    let mut best: Option<(TileKey, f32, i16)> = None;
    for key in tiles.keys() {
        if key.generation != generation || key.page != page {
            continue;
        }
        let cover_scale = crate::engine::quantized_raster_scale_from_lod(key.lod);
        let cover_rect = key.page_rect(cover_scale);
        if !cover_rect.intersects(target_page_rect) {
            continue;
        }
        let distance = (key.lod - target_lod).abs();
        let replace = match best {
            None => true,
            Some((_, _, best_distance)) => {
                distance < best_distance
                    || (distance == best_distance && key.lod < target_lod)
            }
        };
        if replace {
            best = Some((*key, cover_scale, distance));
        }
    }
    best.map(|(key, scale, _)| (key, scale))
}

impl eframe::App for LatticeApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.frame_index = self.frame_index.wrapping_add(1);
        let ctx = ui.ctx().clone();
        self.handle_events(&ctx);
        self.show_toolbar(ui);
        if self.show_home {
            self.show_home_screen(ui);
        } else {
            self.show_split_view(ui);
        }
        self.show_overlays(ui);
        self.handle_keys(&ctx);
        for pane in &mut self.panes[..self.pane_count] {
            Self::prune_tiles(pane, self.frame_index);
        }
        if self.frame_index.is_multiple_of(120) {
            self.save_reading_state();
        }
    }
}

// UI methods in a second impl block for readability.
impl LatticeApp {
    fn show_toolbar(&mut self, root: &mut egui::Ui) {
        egui::Panel::top("toolbar").show(root, |ui| {
            ui.horizontal(|ui| {
                if ui.button("Open").clicked() {
                    self.pick_open();
                }
                if ui.button("Fit").clicked() {
                    let viewport = self.active_pane().viewport;
                    self.apply_command(ReaderCommand::FitWidth, viewport);
                }
                if ui.button("Help").clicked() {
                    self.show_help = true;
                }
                ui.separator();
                let (name, pages, zoom, page) = {
                    let pane = self.active_pane();
                    if let Some(document) = &pane.document {
                        let page = pane
                            .jump_location()
                            .map(|l| l.page_index + 1)
                            .unwrap_or(1);
                        (
                            document
                                .path
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or("PDF")
                                .to_owned(),
                            document.pages.len(),
                            pane.camera.zoom,
                            page,
                        )
                    } else if self.loading {
                        (self.status.clone(), 0, 1.0, 1)
                    } else if self.show_home {
                        ("Home".into(), 0, 1.0, 1)
                    } else {
                        (self.status.clone(), 0, 1.0, 1)
                    }
                };
                ui.label(name);
                if pages > 0 {
                    ui.separator();
                    ui.label(format!("p. {page}/{pages}"));
                    ui.separator();
                    ui.label(format!("{}%", (zoom * 100.0).round()));
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let response = ui.add(
                        egui::TextEdit::singleline(&mut self.search_query)
                            .desired_width(180.0)
                            .hint_text("Search"),
                    );
                    if self.focus_toolbar_search {
                        response.request_focus();
                        self.focus_toolbar_search = false;
                        self.search_ui = SearchUi::Toolbar;
                    }
                    if self.search_ui == SearchUi::Toolbar && response.has_focus() {
                        if ui.input(|i| i.key_pressed(Key::Enter)) {
                            self.run_search();
                        }
                        if ui.input(|i| i.key_pressed(Key::Escape)) {
                            self.search_ui = SearchUi::None;
                        }
                    }
                });
            });
        });
    }

    fn show_home_screen(&mut self, root: &mut egui::Ui) {
        let recents = self.recents.clone();
        for recent in &recents {
            if !self.thumbnails.contains_key(&recent.fingerprint)
                && self.pending_thumbnails.insert(recent.fingerprint.clone())
            {
                self.engine.request_thumbnail(
                    PathBuf::from(&recent.path),
                    recent.fingerprint.clone(),
                );
            }
        }

        egui::CentralPanel::default().show(root, |ui| {
            ui.vertical_centered(|ui| {
                ui.add_space(28.0);
                ui.heading("Lattice");
                ui.label("Recent PDFs");
                ui.add_space(12.0);
            });
            if recents.is_empty() {
                ui.vertical_centered(|ui| {
                    ui.label("No recent documents — press o or Open");
                });
                return;
            }

            egui::ScrollArea::vertical().show(ui, |ui| {
                let mut open_path: Option<PathBuf> = None;
                ui.horizontal_wrapped(|ui| {
                    ui.spacing_mut().item_spacing = Vec2::new(16.0, 16.0);
                    for recent in &recents {
                        let thumb = self.thumbnails.get(&recent.fingerprint).cloned();
                        let response = egui::Frame::group(ui.style())
                            .inner_margin(10.0)
                            .show(ui, |ui| {
                                ui.set_width(HOME_CARD_WIDTH - 20.0);
                                ui.set_min_height(HOME_CARD_HEIGHT - 20.0);
                                ui.vertical_centered(|ui| {
                                    let (thumb_rect, _) =
                                        ui.allocate_exact_size(HOME_THUMB_SIZE, Sense::hover());
                                    ui.painter().rect_filled(
                                        thumb_rect,
                                        4.0,
                                        Color32::from_gray(245),
                                    );
                                    if let Some(texture) = &thumb {
                                        let size = texture.size_vec2();
                                        let scale = (HOME_THUMB_SIZE.x / size.x)
                                            .min(HOME_THUMB_SIZE.y / size.y);
                                        let image_rect = Rect::from_center_size(
                                            thumb_rect.center(),
                                            size * scale,
                                        );
                                        ui.painter().image(
                                            texture.id(),
                                            image_rect,
                                            Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                                            Color32::WHITE,
                                        );
                                    } else {
                                        ui.painter().text(
                                            thumb_rect.center(),
                                            Align2::CENTER_CENTER,
                                            "…",
                                            FontId::proportional(18.0),
                                            Color32::from_gray(140),
                                        );
                                    }
                                    ui.add_space(8.0);
                                    ui.label(egui::RichText::new(&recent.name).strong());
                                    ui.label(format!("{} pages", recent.page_count));
                                });
                            })
                            .response
                            .interact(Sense::click());
                        if response.clicked() {
                            open_path = Some(PathBuf::from(&recent.path));
                        }
                        if response.hovered() {
                            ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                        }
                    }
                });
                if let Some(path) = open_path {
                    self.open_path(path, true);
                }
            });
        });
    }

    fn show_split_view(&mut self, root: &mut egui::Ui) {
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(Color32::from_rgb(38, 40, 44)))
            .show(root, |ui| {
                let full = ui.max_rect();
                if self.pane_count == 1 || self.split_layout == SplitLayout::Single {
                    self.show_pane(ui, 0, full);
                } else if self.split_layout == SplitLayout::Vertical {
                    let mid = full.center().x;
                    let left = Rect::from_min_max(full.min, Pos2::new(mid - 1.0, full.max.y));
                    let right = Rect::from_min_max(Pos2::new(mid + 1.0, full.min.y), full.max);
                    self.show_pane(ui, 0, left);
                    self.show_pane(ui, 1, right);
                } else {
                    let mid = full.center().y;
                    let top = Rect::from_min_max(full.min, Pos2::new(full.max.x, mid - 1.0));
                    let bottom = Rect::from_min_max(Pos2::new(full.min.x, mid + 1.0), full.max);
                    self.show_pane(ui, 0, top);
                    self.show_pane(ui, 1, bottom);
                }
            });
    }

    fn show_pane(&mut self, ui: &mut egui::Ui, pane_index: usize, viewport: Rect) {
        self.panes[pane_index].viewport = viewport;
        let response = ui.allocate_rect(viewport, Sense::click_and_drag());
        if response.clicked() {
            self.active_pane = pane_index;
        }

        let dropped = ui.ctx().input(|input| input.raw.dropped_files.clone());
        if let Some(path) = dropped.into_iter().find_map(|file| file.path) {
            self.active_pane = pane_index;
            self.open_path(path, true);
        }

        let Some(document) = self.panes[pane_index].document.as_ref() else {
            ui.painter().text(
                viewport.center(),
                Align2::CENTER_CENTER,
                if self.loading {
                    self.status.as_str()
                } else {
                    "Drop a PDF here, or choose Open"
                },
                FontId::proportional(18.0),
                Color32::from_gray(190),
            );
            return;
        };

        let doc_size = document.size;
        let generation = document.generation;
        let capturing = self.mark_mode != MarkCaptureMode::Inactive && pane_index == self.active_pane;
        let control = self.control_held && pane_index == self.active_pane;

        if pane_index == self.active_pane && !capturing {
            self.panes[pane_index]
                .camera
                .update(ui.ctx(), viewport, doc_size);
            if response.dragged() && !control {
                let delta = ui.ctx().input(|i| i.pointer.delta());
                self.panes[pane_index].camera.pan_screen(delta);
            }
        }

        // Link clicks
        let mut link_dest: Option<usize> = None;
        if response.clicked()
            && !control
            && !capturing
            && let Some(pos) = response.interact_pointer_pos()
        {
            let doc_pos = self.panes[pane_index]
                .camera
                .screen_to_document(pos, viewport);
            let page = document.page_at_document_y(doc_pos.y);
            let page_rect = document.page_rect(page);
            let local = doc_pos - page_rect.min.to_vec2();
            if let Some(links) = self.panes[pane_index].links.get(&page) {
                for link in links {
                    if link.bounds.contains(Pos2::new(local.x, local.y)) {
                        link_dest = link.dest_page;
                        break;
                    }
                }
            }
        }
        let page_count = document.pages.len();
        let _ = document;

        if let Some(dest) = link_dest {
            self.active_pane = pane_index;
            self.go_to_page(dest);
        }

        let view_doc = self.panes[pane_index]
            .camera
            .visible_document_rect(viewport);
        let raster_scale = crate::engine::quantized_raster_scale(
            self.panes[pane_index].camera.zoom * ui.ctx().pixels_per_point(),
        );
        let lod = crate::engine::scale_to_lod(raster_scale);
        let painter = ui.painter_at(viewport);
            let Some(document) = self.panes[pane_index].document.as_ref() else {
            return;
        };
        for page_index in 0..page_count {
            let page_rect = document.page_rect(page_index);
            if !page_rect.intersects(view_doc) {
                continue;
            }
            let screen_rect = self.panes[pane_index]
                .camera
                .document_to_screen_rect(page_rect, viewport);
            painter.rect_filled(screen_rect, 2.0, Color32::WHITE);
            painter.rect_stroke(
                screen_rect,
                2.0,
                Stroke::new(1.0, Color32::from_black_alpha(80)),
                egui::StrokeKind::Outside,
            );

            if !self.panes[pane_index].display_lists.contains_key(&page_index) {
                if self.panes[pane_index].requested_pages.insert(page_index) {
                    self.engine.request_page(generation, page_index);
                }
                continue;
            }
            let display_list = self.panes[pane_index]
                .display_lists
                .get(&page_index)
                .cloned()
                .unwrap();
            let page_size = self.panes[pane_index].document.as_ref().unwrap().pages[page_index]
                .size();
            let visible_on_page = page_rect
                .intersect(view_doc)
                .translate(-page_rect.min.to_vec2());
            for key in visible_tiles(
                generation,
                page_index,
                lod,
                raster_scale,
                page_size,
                visible_on_page,
            ) {
                let tile_page_rect = key.page_rect(raster_scale);
                let tile_document_rect = tile_page_rect.translate(page_rect.min.to_vec2());
                let tile_screen_rect = self.panes[pane_index]
                    .camera
                    .document_to_screen_rect(tile_document_rect, viewport);
                if let Some(tile) = self.panes[pane_index].tiles.get_mut(&key) {
                    tile.last_used_frame = self.frame_index;
                    painter.image(
                        tile.texture.id(),
                        tile_screen_rect,
                        Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                        Color32::WHITE,
                    );
                } else {
                    if let Some((cover_key, cover_scale)) = find_cover_tile(
                        &self.panes[pane_index].tiles,
                        generation,
                        page_index,
                        tile_page_rect,
                        lod,
                    ) {
                        let cover_page_rect = cover_key.page_rect(cover_scale);
                        let cover_doc = cover_page_rect.translate(page_rect.min.to_vec2());
                        let cover_screen = self.panes[pane_index]
                            .camera
                            .document_to_screen_rect(cover_doc, viewport);
                        if let Some(tile) = self.panes[pane_index].tiles.get_mut(&cover_key) {
                            tile.last_used_frame = self.frame_index;
                            painter.image(
                                tile.texture.id(),
                                cover_screen,
                                Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                                Color32::WHITE,
                            );
                        }
                    }
                    if self.panes[pane_index].pending_tiles.insert(key) {
                        self.engine.request_tile(TileRequest {
                            key,
                            raster_scale,
                            display_list: display_list.clone(),
                        });
                    }
                }
            }
        }

        // Search highlights
        if let Some(index) = self.search_index {
            for (hit_i, hit) in self.search_hits.iter().enumerate() {
                if hit.page >= page_count {
                    continue;
                }
                let page_rect = document.page_rect(hit.page);
                let doc_rect = hit.rect.translate(page_rect.min.to_vec2());
                if !doc_rect.intersects(view_doc) {
                    continue;
                }
                let screen = self.panes[pane_index]
                    .camera
                    .document_to_screen_rect(doc_rect, viewport);
                let color = if hit_i == index {
                    Color32::from_rgba_unmultiplied(255, 214, 10, 120)
                } else {
                    Color32::from_rgba_unmultiplied(255, 214, 10, 60)
                };
                painter.rect_filled(screen, 0.0, color);
            }
        }

        self.draw_marks(ui, pane_index, viewport);
        self.handle_mark_interaction(ui, pane_index, &response, viewport);

        if pane_index == self.active_pane {
            painter.rect_stroke(
                viewport.shrink(1.0),
                0.0,
                Stroke::new(2.0, Color32::from_rgb(80, 160, 255)),
                egui::StrokeKind::Inside,
            );
        }

        if self
            .flash_until
            .is_some_and(|until| Instant::now() < until)
            && pane_index == self.active_pane
        {
            painter.rect_filled(
                viewport,
                0.0,
                Color32::from_rgba_unmultiplied(255, 255, 255, 30),
            );
        }
    }

    fn draw_marks(&mut self, ui: &mut egui::Ui, pane_index: usize, viewport: Rect) {
        let Some(document) = self.panes[pane_index].document.as_ref() else {
            return;
        };
        let fingerprint = document.fingerprint.clone();
        let marks: Vec<Mark> = self
            .marks_for_document(&fingerprint)
            .into_iter()
            .cloned()
            .collect();
        let painter = ui.painter_at(viewport);
        for mark in &marks {
            for endpoint in [MarkEndpoint::Source, MarkEndpoint::Destination] {
                let anchor = mark.anchor(endpoint);
                if anchor.document_fingerprint != fingerprint
                    || anchor.page_index >= document.pages.len()
                {
                    continue;
                }
                let page_rect = document.page_rect(anchor.page_index);
                let Some(page) = MarkGeometry::page_rect(
                    anchor.bounds,
                    [
                        page_rect.min.x,
                        page_rect.min.y,
                        page_rect.width(),
                        page_rect.height(),
                    ],
                ) else {
                    continue;
                };
                let doc_rect =
                    Rect::from_min_size(Pos2::new(page[0], page[1]), Vec2::new(page[2], page[3]));
                let screen = self.panes[pane_index]
                    .camera
                    .document_to_screen_rect(doc_rect, viewport);
                match endpoint {
                    MarkEndpoint::Source => {
                        painter.rect_filled(
                            screen,
                            2.0,
                            Color32::from_rgba_unmultiplied(40, 120, 255, 28),
                        );
                        painter.rect_stroke(
                            screen,
                            2.0,
                            Stroke::new(2.0, Color32::from_rgb(40, 120, 255)),
                            egui::StrokeKind::Outside,
                        );
                    }
                    MarkEndpoint::Destination => {
                        painter.rect_filled(
                            screen,
                            2.0,
                            Color32::from_rgba_unmultiplied(40, 120, 255, 14),
                        );
                        painter.rect_stroke(
                            screen,
                            2.0,
                            Stroke::new(1.5, Color32::from_rgba_unmultiplied(40, 120, 255, 110)),
                            egui::StrokeKind::Outside,
                        );
                    }
                }
            }
        }

        // Live drag rectangle
        if pane_index == self.active_pane
            && let (Some((_, start)), Some(end)) = (self.drag_start, self.drag_current)
        {
            let doc_rect = Rect::from_two_pos(start, end);
            let screen = self.panes[pane_index]
                .camera
                .document_to_screen_rect(doc_rect, viewport);
            painter.rect_stroke(
                screen,
                0.0,
                Stroke::new(1.5, Color32::from_rgb(255, 140, 0)),
                egui::StrokeKind::Outside,
            );
            painter.rect_filled(
                screen,
                0.0,
                Color32::from_rgba_unmultiplied(255, 140, 0, 40),
            );
        }
    }

    fn handle_mark_interaction(
        &mut self,
        ui: &mut egui::Ui,
        pane_index: usize,
        response: &egui::Response,
        viewport: Rect,
    ) {
        if pane_index != self.active_pane {
            return;
        }
        let capturing = self.mark_mode != MarkCaptureMode::Inactive;
        let control = ui.ctx().input(|i| i.modifiers.ctrl);
        self.control_held = control;

        if capturing {
            ui.ctx().set_cursor_icon(egui::CursorIcon::Crosshair);
            if response.drag_started()
                && let Some(pos) = response.interact_pointer_pos()
            {
                let doc_pos = self.panes[pane_index]
                    .camera
                    .screen_to_document(pos, viewport);
                let Some(document) = self.panes[pane_index].document.as_ref() else {
                    return;
                };
                let page = document.page_at_document_y(doc_pos.y);
                self.drag_start = Some((page, doc_pos));
                self.drag_current = Some(doc_pos);
            }
            if response.dragged()
                && let Some(pos) = response.interact_pointer_pos()
            {
                self.drag_current = Some(
                    self.panes[pane_index]
                        .camera
                        .screen_to_document(pos, viewport),
                );
            }
            if response.drag_stopped() {
                self.capture_drag_as_mark();
            }
            return;
        }

        let hover = response.hover_pos().or(response.interact_pointer_pos());
        let Some(pos) = hover else {
            if !control {
                self.pending_preview = None;
                self.preview = None;
                self.preview_anchor = None;
            }
            return;
        };
        let hit = self.hit_test_mark(pane_index, pos, viewport);

        if response.secondary_clicked()
            && !control
            && let Some((mark_id, MarkEndpoint::Source, _)) = hit
        {
            self.delete_mark(mark_id);
            return;
        }

        if !control {
            self.pending_preview = None;
            self.preview = None;
            self.preview_anchor = None;
            return;
        }

        let Some(hit) = hit else {
            self.pending_preview = None;
            self.preview_anchor = None;
            return;
        };

        self.preview_anchor = Some(hit.2);
        let needs_new = self
            .pending_preview
            .as_ref()
            .map(|p| p.mark_id != hit.0 || p.endpoint != hit.1)
            .unwrap_or(true);
        if needs_new {
            self.pending_preview = Some(PendingPreview {
                mark_id: hit.0,
                endpoint: hit.1,
                since: Instant::now(),
            });
            self.preview = None;
        }
        if let Some(pending) = &self.pending_preview
            && pending.since.elapsed() >= PREVIEW_DEBOUNCE
            && self
                .preview
                .as_ref()
                .map(|p| p.mark_id != pending.mark_id || p.endpoint != pending.endpoint)
                .unwrap_or(true)
        {
            self.request_preview(pending.mark_id, pending.endpoint);
        }

        if response.clicked() || response.secondary_clicked() {
            self.activate_mark(hit.0, hit.1);
        }
    }

    fn hit_test_mark(
        &self,
        pane_index: usize,
        screen_pos: Pos2,
        viewport: Rect,
    ) -> Option<(Uuid, MarkEndpoint, Rect)> {
        let document = self.panes[pane_index].document.as_ref()?;
        let fingerprint = &document.fingerprint;
        for mark in self.marks_for_document(fingerprint) {
            for endpoint in [MarkEndpoint::Source, MarkEndpoint::Destination] {
                let anchor = mark.anchor(endpoint);
                if anchor.document_fingerprint != *fingerprint {
                    continue;
                }
                let page_rect = document.page_rect(anchor.page_index);
                let page = MarkGeometry::page_rect(
                    anchor.bounds,
                    [
                        page_rect.min.x,
                        page_rect.min.y,
                        page_rect.width(),
                        page_rect.height(),
                    ],
                )?;
                let doc_rect =
                    Rect::from_min_size(Pos2::new(page[0], page[1]), Vec2::new(page[2], page[3]));
                let screen = self.panes[pane_index]
                    .camera
                    .document_to_screen_rect(doc_rect, viewport);
                if screen.contains(screen_pos) {
                    return Some((mark.id, endpoint, screen));
                }
            }
        }
        None
    }

    fn request_preview(&mut self, mark_id: Uuid, endpoint: MarkEndpoint) {
        let Some(mark) = self.marks.iter().find(|m| m.id == mark_id).cloned() else {
            return;
        };
        let target = mark.opposite_anchor(endpoint).clone();
        let (fingerprint, generation, page_rect) = {
            let Some(document) = self.active_pane().document.as_ref() else {
                return;
            };
            if target.page_index >= document.pages.len() {
                return;
            }
            (
                document.fingerprint.clone(),
                document.generation,
                document.page_rect(target.page_index),
            )
        };
        if target.document_fingerprint != fingerprint {
            self.preview = Some(PreviewState {
                texture: None,
                mark_id,
                endpoint,
                request_id: 0,
            });
            return;
        }
        let Some(page) = MarkGeometry::page_rect(
            target.bounds,
            [
                page_rect.min.x,
                page_rect.min.y,
                page_rect.width(),
                page_rect.height(),
            ],
        ) else {
            return;
        };
        let rect = Rect::from_min_size(Pos2::new(page[0], page[1]), Vec2::new(page[2], page[3]))
            .translate(-page_rect.min.to_vec2());
        self.preview_request_id = self.preview_request_id.wrapping_add(1);
        let request_id = self.preview_request_id;
        self.preview = Some(PreviewState {
            texture: None,
            mark_id,
            endpoint,
            request_id,
        });
        self.engine
            .request_crop(generation, target.page_index, rect, 1.5, request_id);
    }

    fn show_overlays(&mut self, root: &mut egui::Ui) {
        if let Some((generation, path)) = self.password_prompt.clone() {
            egui::Window::new("Password")
                .collapsible(false)
                .resizable(false)
                .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
                .show(root.ctx(), |ui| {
                    ui.label(format!("Password for {}", path.display()));
                    let response = ui.add(
                        egui::TextEdit::singleline(&mut self.password_input)
                            .password(true)
                            .desired_width(240.0),
                    );
                    response.request_focus();
                    ui.horizontal(|ui| {
                        if ui.button("Unlock").clicked()
                            || (response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter)))
                        {
                            self.engine
                                .authenticate(generation, self.password_input.clone());
                            self.loading = true;
                            self.password_prompt = None;
                        }
                        if ui.button("Cancel").clicked() {
                            self.password_prompt = None;
                        }
                    });
                });
        }

        if matches!(self.search_ui, SearchUi::VimForward | SearchUi::VimBackward) {
            egui::Area::new(egui::Id::new("vim_search"))
                .anchor(Align2::CENTER_BOTTOM, [0.0, -24.0])
                .show(root.ctx(), |ui| {
                    egui::Frame::popup(ui.style()).show(ui, |ui| {
                        ui.set_min_width(420.0);
                        let prefix = if self.search_ui == SearchUi::VimForward {
                            "/"
                        } else {
                            "?"
                        };
                        ui.horizontal(|ui| {
                            ui.label(prefix);
                            let response = ui.add(
                                egui::TextEdit::singleline(&mut self.search_query)
                                    .desired_width(360.0),
                            );
                            response.request_focus();
                            if ui.input(|i| i.key_pressed(Key::Enter)) {
                                self.run_search();
                                self.search_ui = SearchUi::None;
                            }
                            if ui.input(|i| i.key_pressed(Key::Escape)) {
                                self.search_ui = SearchUi::None;
                            }
                        });
                    });
                });
        }

        if self.show_palette {
            self.show_command_palette(root);
        }
        if self.show_marks_list {
            self.show_marks_panel(root);
        }
        if self.show_help {
            egui::Window::new("Shortcuts")
                .collapsible(false)
                .resizable(true)
                .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
                .show(root.ctx(), |ui| {
                    ui.label("o  Open");
                    ui.label("j/k/h/l  Scroll");
                    ui.label("Ctrl+d / Ctrl+u  Half page");
                    ui.label("gg / G  Start / end");
                    ui.label("Ctrl+F  Toolbar search");
                    ui.label("/ ?  Vim search");
                    ui.label("m  Mark capture · Ctrl-hover preview · Ctrl-click follow");
                    ui.label("Ctrl+O / Ctrl+I  Jump back / forward");
                    ui.label(":  Command palette");
                    if ui.button("Close").clicked() || ui.input(|i| i.key_pressed(Key::Escape)) {
                        self.show_help = false;
                    }
                });
        }

        if let Some(preview) = &self.preview
            && let Some(texture) = &preview.texture
        {
            let preview_size = texture.size_vec2() * 0.5;
            let screen = root.ctx().content_rect();
            let anchor = self.preview_anchor.unwrap_or_else(|| {
                Rect::from_center_size(screen.center(), Vec2::splat(1.0))
            });
            let mut pos = Pos2::new(anchor.max.x + 12.0, anchor.center().y - preview_size.y * 0.5);
            if pos.x + preview_size.x + 12.0 > screen.max.x {
                pos.x = anchor.min.x - preview_size.x - 12.0;
            }
            pos.y = pos.y.clamp(screen.min.y + 12.0, screen.max.y - preview_size.y - 12.0);
            pos.x = pos.x.clamp(screen.min.x + 12.0, screen.max.x - preview_size.x - 12.0);
            egui::Area::new(egui::Id::new("mark_preview"))
                .fixed_pos(pos)
                .order(egui::Order::Foreground)
                .show(root.ctx(), |ui| {
                    egui::Frame::popup(ui.style())
                        .corner_radius(CornerRadius::same(6))
                        .show(ui, |ui| {
                            ui.image((texture.id(), preview_size));
                        });
                });
        }

        if !self.status.is_empty() && self.show_home == false {
            egui::Area::new(egui::Id::new("status"))
                .anchor(Align2::LEFT_BOTTOM, [12.0, -12.0])
                .show(root.ctx(), |ui| {
                    ui.label(&self.status);
                });
        }
    }

    fn show_command_palette(&mut self, root: &mut egui::Ui) {
        let matches = match_commands(&self.palette_query);
        egui::Window::new("Commands")
            .collapsible(false)
            .resizable(false)
            .anchor(Align2::CENTER_TOP, [0.0, 80.0])
            .show(root.ctx(), |ui| {
                ui.horizontal(|ui| {
                    ui.label(":");
                    let response = ui.add(
                        egui::TextEdit::singleline(&mut self.palette_query).desired_width(360.0),
                    );
                    response.request_focus();
                });
                if ui.input(|i| i.key_pressed(Key::Escape)) {
                    self.show_palette = false;
                }
                if ui.input(|i| i.modifiers.ctrl && i.key_pressed(Key::N)) {
                    self.palette_selection =
                        (self.palette_selection + 1).min(matches.len().saturating_sub(1));
                }
                if ui.input(|i| i.modifiers.ctrl && i.key_pressed(Key::P)) {
                    self.palette_selection = self.palette_selection.saturating_sub(1);
                }
                egui::ScrollArea::vertical().max_height(280.0).show(ui, |ui| {
                    for (index, command) in matches.iter().enumerate() {
                        let selected = index == self.palette_selection;
                        if ui
                            .selectable_label(
                                selected,
                                format!("{} — {}", command.name, command.summary),
                            )
                            .clicked()
                        {
                            self.palette_selection = index;
                            let action = command.action.clone();
                            self.show_palette = false;
                            let viewport = self.active_pane().viewport;
                            self.apply_command(action, viewport);
                            return;
                        }
                    }
                });
                if ui.input(|i| i.key_pressed(Key::Enter)) {
                    if let Some(command) = matches.get(self.palette_selection).cloned()
                        .or_else(|| exact_command(&self.palette_query))
                    {
                        self.show_palette = false;
                        let viewport = self.active_pane().viewport;
                        self.apply_command(command.action, viewport);
                    }
                }
            });
    }

    fn show_marks_panel(&mut self, root: &mut egui::Ui) {
        let fingerprint = self
            .active_pane()
            .document
            .as_ref()
            .map(|d| d.fingerprint.clone())
            .unwrap_or_default();
        let entries: Vec<MarkListEntry> = marks_index_entries(&fingerprint, &self.marks);
        egui::Window::new("Marks")
            .collapsible(false)
            .resizable(true)
            .default_width(420.0)
            .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
            .show(root.ctx(), |ui| {
                if ui.input(|i| i.key_pressed(Key::Escape)) {
                    self.show_marks_list = false;
                }
                if ui.input(|i| i.modifiers.ctrl && i.key_pressed(Key::N)) {
                    self.marks_list_selection =
                        (self.marks_list_selection + 1).min(entries.len().saturating_sub(1));
                }
                if ui.input(|i| i.modifiers.ctrl && i.key_pressed(Key::P)) {
                    self.marks_list_selection = self.marks_list_selection.saturating_sub(1);
                }
                egui::ScrollArea::vertical().max_height(360.0).show(ui, |ui| {
                    for (index, entry) in entries.iter().enumerate() {
                        let label = format!(
                            "p.{} → p.{}  {}",
                            entry.anchor.page_index + 1,
                            entry.counterpart.page_index + 1,
                            entry.anchor.quoted_text.clone().unwrap_or_default()
                        );
                        if ui
                            .selectable_label(index == self.marks_list_selection, label)
                            .clicked()
                        {
                            self.marks_list_selection = index;
                            self.activate_mark(entry.mark_id, entry.endpoint);
                            self.show_marks_list = false;
                        }
                    }
                });
                if ui.input(|i| i.key_pressed(Key::Enter))
                    && let Some(entry) = entries.get(self.marks_list_selection)
                {
                    self.activate_mark(entry.mark_id, entry.endpoint);
                    self.show_marks_list = false;
                }
            });
    }
}

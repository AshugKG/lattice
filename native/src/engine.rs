use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;

use crossbeam_channel::{Receiver, Sender, unbounded};
use eframe::egui::{Context, Rect, Vec2};
use mupdf::{
    Colorspace, Device, DisplayList, Document, IRect, Matrix, Rect as MuRect, TextExtractOptions,
};

pub const TILE_SIZE: i32 = 512;

#[derive(Clone, Copy, Debug)]
pub struct PageInfo {
    pub width: f32,
    pub height: f32,
}

impl PageInfo {
    pub fn size(self) -> Vec2 {
        Vec2::new(self.width, self.height)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TileKey {
    pub generation: u64,
    pub page: usize,
    pub lod: i16,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl TileKey {
    pub fn page_rect(self, raster_scale: f32) -> Rect {
        Rect::from_min_size(
            eframe::egui::pos2(
                (self.x * TILE_SIZE) as f32 / raster_scale,
                (self.y * TILE_SIZE) as f32 / raster_scale,
            ),
            Vec2::new(
                self.width as f32 / raster_scale,
                self.height as f32 / raster_scale,
            ),
        )
    }

    fn pixel_rect(self) -> IRect {
        let x0 = self.x * TILE_SIZE;
        let y0 = self.y * TILE_SIZE;
        IRect::new(x0, y0, x0 + self.width, y0 + self.height)
    }
}

#[derive(Debug)]
pub struct TileImage {
    pub width: usize,
    pub height: usize,
    pub rgb: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct SearchHit {
    pub page: usize,
    pub rect: Rect,
}

#[derive(Clone, Debug)]
pub struct PageLink {
    #[allow(dead_code)]
    pub page: usize,
    pub bounds: Rect,
    pub dest_page: Option<usize>,
    #[allow(dead_code)]
    pub uri: String,
}

#[derive(Clone, Debug)]
pub struct CropImage {
    pub width: usize,
    pub height: usize,
    pub rgb: Vec<u8>,
}

pub enum EngineEvent {
    Opened {
        generation: u64,
        path: PathBuf,
        pages: Vec<PageInfo>,
        fingerprint: String,
        needs_password: bool,
    },
    PasswordRequired {
        generation: u64,
        path: PathBuf,
    },
    PageReady {
        generation: u64,
        page: usize,
        display_list: Arc<DisplayList>,
    },
    TileReady {
        key: TileKey,
        image: TileImage,
    },
    SearchReady {
        generation: u64,
        query: String,
        hits: Vec<SearchHit>,
    },
    LinksReady {
        generation: u64,
        page: usize,
        links: Vec<PageLink>,
    },
    TextReady {
        generation: u64,
        page: usize,
        rect: Rect,
        text: String,
    },
    CropReady {
        generation: u64,
        page: usize,
        rect: Rect,
        image: CropImage,
        request_id: u64,
    },
    Failed(String),
}

enum DocumentCommand {
    Open(PathBuf),
    Authenticate {
        generation: u64,
        password: String,
    },
    Page {
        generation: u64,
        page: usize,
    },
    Search {
        generation: u64,
        query: String,
    },
    Links {
        generation: u64,
        page: usize,
    },
    TextUnderRect {
        generation: u64,
        page: usize,
        rect: Rect,
    },
    Crop {
        generation: u64,
        page: usize,
        rect: Rect,
        scale: f32,
        request_id: u64,
    },
}

pub struct TileRequest {
    pub key: TileKey,
    pub raster_scale: f32,
    pub display_list: Arc<DisplayList>,
}

pub struct Engine {
    document_tx: Sender<DocumentCommand>,
    tile_tx: Sender<TileRequest>,
    event_rx: Receiver<EngineEvent>,
}

impl Engine {
    pub fn new(context: Context) -> Self {
        let (document_tx, document_rx) = unbounded();
        let (tile_tx, tile_rx) = unbounded();
        let (event_tx, event_rx) = unbounded();

        spawn_document_thread(document_rx, event_tx.clone(), context.clone());
        let workers = thread::available_parallelism()
            .map_or(2, usize::from)
            .clamp(2, 6);
        for worker in 0..workers {
            spawn_render_thread(worker, tile_rx.clone(), event_tx.clone(), context.clone());
        }

        Self {
            document_tx,
            tile_tx,
            event_rx,
        }
    }

    pub fn open(&self, path: PathBuf) {
        let _ = self.document_tx.send(DocumentCommand::Open(path));
    }

    pub fn authenticate(&self, generation: u64, password: String) {
        let _ = self
            .document_tx
            .send(DocumentCommand::Authenticate { generation, password });
    }

    pub fn request_page(&self, generation: u64, page: usize) {
        let _ = self
            .document_tx
            .send(DocumentCommand::Page { generation, page });
    }

    pub fn request_tile(&self, request: TileRequest) {
        let _ = self.tile_tx.send(request);
    }

    pub fn search(&self, generation: u64, query: String) {
        let _ = self
            .document_tx
            .send(DocumentCommand::Search { generation, query });
    }

    pub fn request_links(&self, generation: u64, page: usize) {
        let _ = self
            .document_tx
            .send(DocumentCommand::Links { generation, page });
    }

    pub fn text_under_rect(&self, generation: u64, page: usize, rect: Rect) {
        let _ = self.document_tx.send(DocumentCommand::TextUnderRect {
            generation,
            page,
            rect,
        });
    }

    pub fn request_crop(
        &self,
        generation: u64,
        page: usize,
        rect: Rect,
        scale: f32,
        request_id: u64,
    ) {
        let _ = self.document_tx.send(DocumentCommand::Crop {
            generation,
            page,
            rect,
            scale,
            request_id,
        });
    }

    pub fn try_recv(&self) -> Option<EngineEvent> {
        self.event_rx.try_recv().ok()
    }
}

fn spawn_document_thread(
    commands: Receiver<DocumentCommand>,
    events: Sender<EngineEvent>,
    context: Context,
) {
    thread::Builder::new()
        .name("lattice-document".into())
        .spawn(move || {
            let mut generation = 0_u64;
            let mut document: Option<Document> = None;
            let mut open_path: Option<PathBuf> = None;
            while let Ok(command) = commands.recv() {
                match command {
                    DocumentCommand::Open(path) => {
                        generation = generation.wrapping_add(1);
                        open_path = Some(path.clone());
                        match try_open_document(&path, None) {
                            OpenResult::Ready(opened, pages, fingerprint) => {
                                document = Some(opened);
                                let _ = events.send(EngineEvent::Opened {
                                    generation,
                                    path,
                                    pages,
                                    fingerprint,
                                    needs_password: false,
                                });
                            }
                            OpenResult::NeedsPassword => {
                                document = None;
                                let _ = events.send(EngineEvent::PasswordRequired {
                                    generation,
                                    path,
                                });
                            }
                            OpenResult::Failed(error) => {
                                document = None;
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::Authenticate {
                        generation: requested,
                        password,
                    } if requested == generation => {
                        let Some(path) = open_path.clone() else {
                            let _ = events.send(EngineEvent::Failed("No PDF is open".into()));
                            continue;
                        };
                        match try_open_document(&path, Some(&password)) {
                            OpenResult::Ready(opened, pages, fingerprint) => {
                                document = Some(opened);
                                let _ = events.send(EngineEvent::Opened {
                                    generation,
                                    path,
                                    pages,
                                    fingerprint,
                                    needs_password: false,
                                });
                            }
                            OpenResult::NeedsPassword => {
                                let _ = events.send(EngineEvent::Failed(
                                    "Incorrect password".into(),
                                ));
                                let _ = events.send(EngineEvent::PasswordRequired {
                                    generation,
                                    path,
                                });
                            }
                            OpenResult::Failed(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::Page {
                        generation: requested_generation,
                        page,
                    } if requested_generation == generation => {
                        let result = document
                            .as_ref()
                            .ok_or_else(|| "No PDF is open".to_owned())
                            .and_then(|document| {
                                document
                                    .load_page(page as i32)
                                    .and_then(|page| page.to_display_list(true))
                                    .map(Arc::new)
                                    .map_err(|error| {
                                        format!("Could not prepare page {}: {error}", page + 1)
                                    })
                            });
                        match result {
                            Ok(display_list) => {
                                let _ = events.send(EngineEvent::PageReady {
                                    generation,
                                    page,
                                    display_list,
                                });
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::Search {
                        generation: requested,
                        query,
                    } if requested == generation => {
                        let hits = match &document {
                            Some(document) => search_document(document, &query),
                            None => Err("No PDF is open".into()),
                        };
                        match hits {
                            Ok(hits) => {
                                let _ = events.send(EngineEvent::SearchReady {
                                    generation,
                                    query,
                                    hits,
                                });
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::Links {
                        generation: requested,
                        page,
                    } if requested == generation => {
                        let links = match &document {
                            Some(document) => load_links(document, page),
                            None => Err("No PDF is open".into()),
                        };
                        match links {
                            Ok(links) => {
                                let _ = events.send(EngineEvent::LinksReady {
                                    generation,
                                    page,
                                    links,
                                });
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::TextUnderRect {
                        generation: requested,
                        page,
                        rect,
                    } if requested == generation => {
                        let text = match &document {
                            Some(document) => text_under_rect(document, page, rect),
                            None => Err("No PDF is open".into()),
                        };
                        match text {
                            Ok(text) => {
                                let _ = events.send(EngineEvent::TextReady {
                                    generation,
                                    page,
                                    rect,
                                    text,
                                });
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    DocumentCommand::Crop {
                        generation: requested,
                        page,
                        rect,
                        scale,
                        request_id,
                    } if requested == generation => {
                        let image = match &document {
                            Some(document) => render_crop(document, page, rect, scale),
                            None => Err("No PDF is open".into()),
                        };
                        match image {
                            Ok(image) => {
                                let _ = events.send(EngineEvent::CropReady {
                                    generation,
                                    page,
                                    rect,
                                    image,
                                    request_id,
                                });
                            }
                            Err(error) => {
                                let _ = events.send(EngineEvent::Failed(error));
                            }
                        }
                    }
                    _ => {}
                }
                context.request_repaint();
            }
        })
        .expect("failed to start MuPDF document thread");
}

enum OpenResult {
    Ready(Document, Vec<PageInfo>, String),
    NeedsPassword,
    Failed(String),
}

fn try_open_document(path: &Path, password: Option<&str>) -> OpenResult {
    let fingerprint = match crate::persist::fingerprint_file(path) {
        Ok(value) => value,
        Err(error) => return OpenResult::Failed(error),
    };
    let mut document = match Document::open(path) {
        Ok(document) => document,
        Err(error) => return OpenResult::Failed(format!("Could not open PDF: {error}")),
    };
    if !document.is_pdf() {
        return OpenResult::Failed("The selected file is not a PDF".into());
    }
    let needs = match document.needs_password() {
        Ok(value) => value,
        Err(error) => return OpenResult::Failed(format!("Could not inspect PDF: {error}")),
    };
    if needs {
        let Some(password) = password else {
            return OpenResult::NeedsPassword;
        };
        match document.authenticate(password) {
            Ok(true) => {}
            Ok(false) => return OpenResult::NeedsPassword,
            Err(error) => {
                return OpenResult::Failed(format!("Could not authenticate PDF: {error}"));
            }
        }
    }
    match page_infos(&document) {
        Ok(pages) => OpenResult::Ready(document, pages, fingerprint),
        Err(error) => OpenResult::Failed(error),
    }
}

fn page_infos(document: &Document) -> Result<Vec<PageInfo>, String> {
    let count = document
        .page_count()
        .map_err(|error| format!("Could not count PDF pages: {error}"))?;
    let mut pages = Vec::with_capacity(count.max(0) as usize);
    for index in 0..count {
        let bounds = document
            .load_page(index)
            .and_then(|page| page.bounds())
            .map_err(|error| format!("Could not inspect page {}: {error}", index + 1))?;
        pages.push(PageInfo {
            width: bounds.width(),
            height: bounds.height(),
        });
    }
    Ok(pages)
}

fn search_document(document: &Document, query: &str) -> Result<Vec<SearchHit>, String> {
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }
    let count = document
        .page_count()
        .map_err(|e| format!("Could not search PDF: {e}"))?;
    let mut hits = Vec::new();
    for page_index in 0..count {
        let page = document
            .load_page(page_index)
            .map_err(|e| format!("Could not search page {}: {e}", page_index + 1))?;
        let quads = page
            .search(query, 32)
            .map_err(|e| format!("Could not search page {}: {e}", page_index + 1))?;
        for quad in quads.iter() {
            let xs = [quad.ul.x, quad.ur.x, quad.ll.x, quad.lr.x];
            let ys = [quad.ul.y, quad.ur.y, quad.ll.y, quad.lr.y];
            let min_x = xs.into_iter().fold(f32::INFINITY, f32::min);
            let max_x = xs.into_iter().fold(f32::NEG_INFINITY, f32::max);
            let min_y = ys.into_iter().fold(f32::INFINITY, f32::min);
            let max_y = ys.into_iter().fold(f32::NEG_INFINITY, f32::max);
            hits.push(SearchHit {
                page: page_index as usize,
                rect: Rect::from_min_max(
                    eframe::egui::pos2(min_x, min_y),
                    eframe::egui::pos2(max_x, max_y),
                ),
            });
        }
    }
    Ok(hits)
}

fn load_links(document: &Document, page_index: usize) -> Result<Vec<PageLink>, String> {
    let page = document
        .load_page(page_index as i32)
        .map_err(|e| format!("Could not load links: {e}"))?;
    let mut links = Vec::new();
    for link in page
        .links()
        .map_err(|e| format!("Could not read links: {e}"))?
    {
        let bounds = Rect::from_min_max(
            eframe::egui::pos2(link.bounds.x0, link.bounds.y0),
            eframe::egui::pos2(link.bounds.x1, link.bounds.y1),
        );
        let dest_page = link.dest.map(|dest| dest.loc.page_number as usize);
        links.push(PageLink {
            page: page_index,
            bounds,
            dest_page,
            uri: link.uri,
        });
    }
    Ok(links)
}

fn text_under_rect(document: &Document, page_index: usize, rect: Rect) -> Result<String, String> {
    let page = document
        .load_page(page_index as i32)
        .map_err(|e| format!("Could not extract text: {e}"))?;
    let words = page
        .words(TextExtractOptions::default())
        .map_err(|e| format!("Could not extract text: {e}"))?;
    let mut parts = Vec::new();
    for word in words {
        let word_rect = Rect::from_min_max(
            eframe::egui::pos2(word.bounds.x0, word.bounds.y0),
            eframe::egui::pos2(word.bounds.x1, word.bounds.y1),
        );
        if word_rect.intersects(rect) {
            parts.push(word.text);
        }
    }
    Ok(parts.join(" "))
}

fn render_crop(
    document: &Document,
    page_index: usize,
    rect: Rect,
    scale: f32,
) -> Result<CropImage, String> {
    let page = document
        .load_page(page_index as i32)
        .map_err(|e| format!("Could not render preview: {e}"))?;
    let scale = scale.clamp(0.5, 3.0);
    let width = (rect.width() * scale).ceil().max(1.0) as i32;
    let height = (rect.height() * scale).ceil().max(1.0) as i32;
    let mut pixmap = mupdf::Pixmap::new_with_w_h(&Colorspace::device_rgb(), width, height, false)
        .map_err(|e| format!("Could not render preview: {e}"))?;
    pixmap
        .clear_with(255)
        .map_err(|e| format!("Could not render preview: {e}"))?;
    let device = Device::from_pixmap(&pixmap).map_err(|e| format!("Could not render preview: {e}"))?;
    let mut matrix = Matrix::new_scale(scale, scale);
    matrix.pre_translate(-rect.min.x, -rect.min.y);
    page.run(&device, &matrix)
        .map_err(|e| format!("Could not render preview: {e}"))?;
    drop(device);
    let components = pixmap.n() as usize;
    let mut rgb = Vec::with_capacity((width * height * 3) as usize);
    for row in pixmap.samples().chunks(pixmap.stride() as usize) {
        for pixel in row[..width as usize * components].chunks_exact(components) {
            rgb.extend_from_slice(&pixel[..3]);
        }
    }
    Ok(CropImage {
        width: width as usize,
        height: height as usize,
        rgb,
    })
}

fn spawn_render_thread(
    worker: usize,
    requests: Receiver<TileRequest>,
    events: Sender<EngineEvent>,
    context: Context,
) {
    thread::Builder::new()
        .name(format!("lattice-render-{worker}"))
        .spawn(move || {
            while let Ok(request) = requests.recv() {
                match render_tile(&request) {
                    Ok(image) => {
                        let _ = events.send(EngineEvent::TileReady {
                            key: request.key,
                            image,
                        });
                    }
                    Err(error) => {
                        let _ = events.send(EngineEvent::Failed(format!(
                            "Could not render page {}: {error}",
                            request.key.page + 1
                        )));
                    }
                }
                context.request_repaint();
            }
        })
        .expect("failed to start MuPDF render worker");
}

fn render_tile(request: &TileRequest) -> Result<TileImage, mupdf::Error> {
    let rect = request.key.pixel_rect();
    let mut pixmap = mupdf::Pixmap::new_with_rect(&Colorspace::device_rgb(), rect, false)?;
    pixmap.clear_with(255)?;
    let device = Device::from_pixmap_with_clip(&pixmap, rect)?;
    let bounds = request.display_list.bounds();
    let mut matrix = Matrix::new_scale(request.raster_scale, request.raster_scale);
    matrix.pre_translate(-bounds.x0, -bounds.y0);
    let area = MuRect::new(
        rect.x0 as f32,
        rect.y0 as f32,
        rect.x1 as f32,
        rect.y1 as f32,
    );
    request.display_list.run(&device, &matrix, area)?;
    drop(device);

    let width = pixmap.width() as usize;
    let height = pixmap.height() as usize;
    let components = pixmap.n() as usize;
    let mut rgb = Vec::with_capacity(width * height * 3);
    for row in pixmap.samples().chunks(pixmap.stride() as usize) {
        for pixel in row[..width * components].chunks_exact(components) {
            rgb.extend_from_slice(&pixel[..3]);
        }
    }
    Ok(TileImage { width, height, rgb })
}

pub fn scale_to_lod(scale: f32) -> i16 {
    (scale.log2() * 4.0).round() as i16
}

pub fn quantized_raster_scale(scale: f32) -> f32 {
    2.0_f32.powf(scale_to_lod(scale) as f32 / 4.0)
}

pub fn visible_tiles(
    generation: u64,
    page: usize,
    lod: i16,
    raster_scale: f32,
    page_size: Vec2,
    visible: Rect,
) -> Vec<TileKey> {
    let page_pixels = Vec2::new(
        (page_size.x * raster_scale).ceil(),
        (page_size.y * raster_scale).ceil(),
    );
    let x0 = ((visible.min.x * raster_scale) as i32 / TILE_SIZE).max(0);
    let y0 = ((visible.min.y * raster_scale) as i32 / TILE_SIZE).max(0);
    let x1 = ((visible.max.x * raster_scale).ceil() as i32 / TILE_SIZE)
        .min((page_pixels.x as i32 + TILE_SIZE - 1) / TILE_SIZE);
    let y1 = ((visible.max.y * raster_scale).ceil() as i32 / TILE_SIZE)
        .min((page_pixels.y as i32 + TILE_SIZE - 1) / TILE_SIZE);
    let mut keys = Vec::new();
    for y in y0..=y1 {
        for x in x0..=x1 {
            let pixel_x = x * TILE_SIZE;
            let pixel_y = y * TILE_SIZE;
            let width = (page_pixels.x as i32 - pixel_x).clamp(0, TILE_SIZE);
            let height = (page_pixels.y as i32 - pixel_y).clamp(0, TILE_SIZE);
            if width > 0 && height > 0 {
                keys.push(TileKey {
                    generation,
                    page,
                    lod,
                    x,
                    y,
                    width,
                    height,
                });
            }
        }
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lod_round_trips_to_quantized_scale() {
        let scale = quantized_raster_scale(1.49);
        assert_eq!(scale_to_lod(scale), scale_to_lod(1.49));
    }

    #[test]
    fn visible_tiles_clip_at_page_edge() {
        let tiles = visible_tiles(
            1,
            0,
            0,
            1.0,
            Vec2::new(600.0, 700.0),
            Rect::from_min_size(eframe::egui::Pos2::ZERO, Vec2::new(600.0, 700.0)),
        );
        assert_eq!(tiles.len(), 4);
        assert!(
            tiles
                .iter()
                .any(|tile| tile.width == 88 && tile.height == 188)
        );
    }
}

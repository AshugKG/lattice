use eframe::egui::{Context, Pos2, Rect, Vec2};

pub const MIN_ZOOM: f32 = 0.25;
pub const MAX_ZOOM: f32 = 8.0;
const LINE_SCROLL: f32 = 88.0;

#[derive(Debug, Clone)]
pub struct Camera {
    pub zoom: f32,
    origin: Pos2,
}

impl Default for Camera {
    fn default() -> Self {
        Self {
            zoom: 1.0,
            origin: Pos2::ZERO,
        }
    }
}

impl Camera {
    pub fn update(&mut self, ctx: &Context, viewport: Rect, document_size: Vec2) {
        let (scroll, zoom_delta, pointer) = ctx.input(|input| {
            (
                input.smooth_scroll_delta,
                input.zoom_delta(),
                input.pointer.hover_pos(),
            )
        });

        if scroll != Vec2::ZERO && (zoom_delta - 1.0).abs() <= f32::EPSILON {
            self.origin -= scroll / self.zoom;
        }

        if (zoom_delta - 1.0).abs() > f32::EPSILON {
            let focal_screen = pointer
                .filter(|point| viewport.contains(*point))
                .unwrap_or_else(|| viewport.center());
            let focal_view = focal_screen - viewport.min;
            let focal_document = self.origin + focal_view / self.zoom;
            self.zoom = (self.zoom * zoom_delta).clamp(MIN_ZOOM, MAX_ZOOM);
            self.origin = focal_document - focal_view / self.zoom;
        }

        self.clamp(viewport, document_size);
    }

    pub fn pan_screen(&mut self, delta: Vec2) {
        self.origin -= delta / self.zoom;
    }

    pub fn scroll_by_screen(&mut self, delta: Vec2, viewport: Rect, document_size: Vec2) {
        self.origin += delta / self.zoom;
        self.clamp(viewport, document_size);
    }

    pub fn scroll_lines(&mut self, lines: f32, viewport: Rect, document_size: Vec2) {
        self.scroll_by_screen(Vec2::new(0.0, lines * LINE_SCROLL), viewport, document_size);
    }

    pub fn scroll_half(&mut self, down: bool, viewport: Rect, document_size: Vec2) {
        let amount = viewport.height() * 0.5 * if down { 1.0 } else { -1.0 };
        self.scroll_by_screen(Vec2::new(0.0, amount), viewport, document_size);
    }

    pub fn zoom_by(&mut self, factor: f32, viewport: Rect, document_size: Vec2) {
        let focal = viewport.center();
        let focal_view = focal - viewport.min;
        let focal_document = self.origin + focal_view / self.zoom;
        self.zoom = (self.zoom * factor).clamp(MIN_ZOOM, MAX_ZOOM);
        self.origin = focal_document - focal_view / self.zoom;
        self.clamp(viewport, document_size);
    }

    pub fn fit_width(&mut self, viewport: Rect, document_width: f32, document_size: Vec2) {
        if document_width <= 0.0 || viewport.width() <= 0.0 {
            return;
        }
        self.zoom = (viewport.width() / document_width).clamp(MIN_ZOOM, MAX_ZOOM);
        self.clamp(viewport, document_size);
    }

    pub fn go_to_document_y(&mut self, y: f32, viewport: Rect, document_size: Vec2) {
        self.origin.y = y;
        self.clamp(viewport, document_size);
    }

    pub fn go_to_point(
        &mut self,
        document_point: Pos2,
        viewport: Rect,
        document_size: Vec2,
        zoom: Option<f32>,
    ) {
        if let Some(zoom) = zoom {
            self.zoom = zoom.clamp(MIN_ZOOM, MAX_ZOOM);
        }
        let visible = viewport.size() / self.zoom;
        self.origin = Pos2::new(
            document_point.x - visible.x * 0.5,
            document_point.y - visible.y * 0.5,
        );
        self.clamp(viewport, document_size);
    }

    pub fn visible_document_rect(&self, viewport: Rect) -> Rect {
        Rect::from_min_size(self.origin, viewport.size() / self.zoom)
    }

    pub fn document_to_screen_rect(&self, rect: Rect, viewport: Rect) -> Rect {
        Rect::from_min_max(
            viewport.min + (rect.min - self.origin) * self.zoom,
            viewport.min + (rect.max - self.origin) * self.zoom,
        )
    }

    pub fn screen_to_document(&self, screen: Pos2, viewport: Rect) -> Pos2 {
        self.origin + (screen - viewport.min) / self.zoom
    }

    pub fn viewport_center_document(&self, viewport: Rect) -> Pos2 {
        self.origin + (viewport.size() * 0.5) / self.zoom
    }

    pub fn clamp(&mut self, viewport: Rect, document_size: Vec2) {
        let visible = viewport.size() / self.zoom;
        self.origin.x = self
            .origin
            .x
            .clamp(0.0, (document_size.x - visible.x).max(0.0));
        self.origin.y = self
            .origin
            .y
            .clamp(0.0, (document_size.y - visible.y).max(0.0));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_screen_transform_is_stable() {
        let camera = Camera {
            zoom: 2.0,
            origin: Pos2::new(10.0, 20.0),
        };
        let viewport = Rect::from_min_size(Pos2::new(100.0, 50.0), Vec2::new(800.0, 600.0));
        let result = camera.document_to_screen_rect(
            Rect::from_min_size(Pos2::new(15.0, 30.0), Vec2::new(20.0, 40.0)),
            viewport,
        );
        assert_eq!(result.min, Pos2::new(110.0, 70.0));
        assert_eq!(result.size(), Vec2::new(40.0, 80.0));
    }
}

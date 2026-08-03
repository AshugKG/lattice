use super::NormalizedPoint;

#[derive(Clone, Debug, PartialEq)]
pub struct JumpLocation {
    pub document_fingerprint: String,
    pub document_path: String,
    pub page_index: usize,
    pub viewport_center: NormalizedPoint,
    pub scale_factor: f64,
}

impl JumpLocation {
    pub const HOME_FINGERPRINT: &'static str = "lattice:home";

    pub fn new(
        document_fingerprint: impl Into<String>,
        document_path: impl Into<String>,
        page_index: usize,
        viewport_center: NormalizedPoint,
        scale_factor: f64,
    ) -> Self {
        Self {
            document_fingerprint: document_fingerprint.into(),
            document_path: document_path.into(),
            page_index,
            viewport_center,
            scale_factor,
        }
    }

    pub fn home() -> Self {
        Self::new(
            Self::HOME_FINGERPRINT,
            "",
            0,
            NormalizedPoint::new(0.5, 0.5),
            1.0,
        )
    }

    pub fn is_home(&self) -> bool {
        self.document_fingerprint == Self::HOME_FINGERPRINT
    }

    pub fn is_equivalent(&self, other: &Self) -> bool {
        if self.is_home() || other.is_home() {
            return self.is_home() && other.is_home();
        }
        self.document_fingerprint == other.document_fingerprint
            && self.page_index == other.page_index
            && (self.viewport_center.x - other.viewport_center.x).abs() < 0.002
            && (self.viewport_center.y - other.viewport_center.y).abs() < 0.002
            && (self.scale_factor - other.scale_factor).abs() < 0.01
    }

    pub fn clamped(self, page_count: usize, minimum_scale: f64, maximum_scale: f64) -> Self {
        let page_index = if page_count == 0 {
            0
        } else {
            self.page_index.min(page_count - 1)
        };
        Self {
            document_fingerprint: self.document_fingerprint,
            document_path: self.document_path,
            page_index,
            viewport_center: self.viewport_center.clamp(),
            scale_factor: if self.scale_factor.is_finite() {
                self.scale_factor.clamp(minimum_scale, maximum_scale)
            } else {
                1.0
            },
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct JumpList {
    capacity: usize,
    pub backward: Vec<JumpLocation>,
    pub forward: Vec<JumpLocation>,
}

impl JumpList {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            backward: Vec::new(),
            forward: Vec::new(),
        }
    }

    pub fn record_before_jump(&mut self, location: JumpLocation) {
        if self
            .backward
            .last()
            .is_some_and(|last| last.is_equivalent(&location))
        {
            return;
        }
        self.append(location, true);
        self.forward.clear();
    }

    pub fn go_backward(&mut self, current: Option<JumpLocation>) -> Option<JumpLocation> {
        let target = self.backward.pop()?;
        if let Some(current) = current {
            self.append(current, false);
        }
        Some(target)
    }

    pub fn go_forward(&mut self, current: Option<JumpLocation>) -> Option<JumpLocation> {
        let target = self.forward.pop()?;
        if let Some(current) = current {
            self.append(current, true);
        }
        Some(target)
    }

    pub fn cancel_backward(&mut self, target: JumpLocation, current: Option<&JumpLocation>) {
        if let Some(current) = current
            && self
                .forward
                .last()
                .is_some_and(|last| last.is_equivalent(current))
        {
            self.forward.pop();
        }
        self.append(target, true);
    }

    pub fn cancel_forward(&mut self, target: JumpLocation, current: Option<&JumpLocation>) {
        if let Some(current) = current
            && self
                .backward
                .last()
                .is_some_and(|last| last.is_equivalent(current))
        {
            self.backward.pop();
        }
        self.append(target, false);
    }

    pub fn rewrite_fingerprint(&mut self, old: &str, new: &str, path: &str) {
        if old == new {
            return;
        }
        self.backward = self
            .backward
            .drain(..)
            .map(|loc| rewrite(loc, old, new, path))
            .collect();
        self.forward = self
            .forward
            .drain(..)
            .map(|loc| rewrite(loc, old, new, path))
            .collect();
    }

    fn append(&mut self, location: JumpLocation, to_backward: bool) {
        let stack = if to_backward {
            &mut self.backward
        } else {
            &mut self.forward
        };
        if stack
            .last()
            .is_some_and(|last| last.is_equivalent(&location))
        {
            return;
        }
        stack.push(location);
        if stack.len() > self.capacity {
            let remove = stack.len() - self.capacity;
            stack.drain(0..remove);
        }
    }
}

fn rewrite(location: JumpLocation, old: &str, new: &str, path: &str) -> JumpLocation {
    if location.is_home() {
        return location;
    }
    let matches_fingerprint = location.document_fingerprint == old;
    let matches_pending_path = location.document_path == path
        && (location.document_fingerprint.starts_with("pending:")
            || location.document_fingerprint == old);
    if !matches_fingerprint && !matches_pending_path {
        return location;
    }
    JumpLocation::new(
        new,
        path,
        location.page_index,
        location.viewport_center,
        location.scale_factor,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loc(page: usize) -> JumpLocation {
        JumpLocation::new(
            "document",
            "/tmp/document.pdf",
            page,
            NormalizedPoint::new(0.5, 0.5),
            1.25,
        )
    }

    fn loc_xy(page: usize, x: f64) -> JumpLocation {
        JumpLocation::new(
            "document",
            "/tmp/document.pdf",
            page,
            NormalizedPoint::new(x, 0.5),
            1.25,
        )
    }

    #[test]
    fn traverses_and_clears_forward() {
        let mut jumps = JumpList::new(3);
        jumps.record_before_jump(loc(1));
        jumps.record_before_jump(loc(2));
        assert_eq!(jumps.go_backward(Some(loc(3))).unwrap().page_index, 2);
        assert_eq!(jumps.go_backward(Some(loc(2))).unwrap().page_index, 1);
        assert_eq!(jumps.go_forward(Some(loc(1))).unwrap().page_index, 2);
        jumps.record_before_jump(loc(9));
        assert!(jumps.forward.is_empty());
    }

    #[test]
    fn home_and_cross_document() {
        let mut jumps = JumpList::new(100);
        let first = JumpLocation::new("a", "/tmp/a.pdf", 2, NormalizedPoint::new(0.5, 0.5), 1.25);
        let second = JumpLocation::new("b", "/tmp/b.pdf", 5, NormalizedPoint::new(0.5, 0.5), 1.25);
        jumps.record_before_jump(first.clone());
        jumps.record_before_jump(second.clone());
        assert_eq!(jumps.go_backward(Some(JumpLocation::home())), Some(second.clone()));
        assert!(jumps.forward.last().unwrap().is_home());
        assert!(jumps.go_forward(Some(second.clone())).unwrap().is_home());
        assert_eq!(jumps.go_backward(Some(JumpLocation::home())), Some(second.clone()));
        assert_eq!(jumps.go_backward(Some(second.clone())), Some(first.clone()));
        assert_eq!(jumps.go_forward(Some(first)), Some(second.clone()));
        assert!(jumps.go_forward(Some(second)).unwrap().is_home());
    }

    #[test]
    fn capacity_and_dedupe() {
        let mut jumps = JumpList::new(2);
        jumps.record_before_jump(loc(1));
        jumps.record_before_jump(loc_xy(1, 0.500_5));
        jumps.record_before_jump(loc(2));
        jumps.record_before_jump(loc(3));
        assert_eq!(
            jumps.backward.iter().map(|l| l.page_index).collect::<Vec<_>>(),
            vec![2, 3]
        );
    }

    #[test]
    fn rewrite_pending_fingerprints() {
        let mut jumps = JumpList::new(100);
        let first = JumpLocation::new(
            "pending:/tmp/a.pdf",
            "/tmp/a.pdf",
            1,
            NormalizedPoint::new(0.5, 0.5),
            1.25,
        );
        jumps.record_before_jump(JumpLocation::home());
        jumps.record_before_jump(first);
        jumps.record_before_jump(JumpLocation::home());
        let second = JumpLocation::new(
            "pending:/tmp/b.pdf",
            "/tmp/b.pdf",
            3,
            NormalizedPoint::new(0.5, 0.5),
            1.25,
        );
        jumps.record_before_jump(second);
        jumps.rewrite_fingerprint("pending:/tmp/a.pdf", "sha-a", "/tmp/a.pdf");
        jumps.rewrite_fingerprint("pending:/tmp/b.pdf", "sha-b", "/tmp/b.pdf");
        assert_eq!(
            jumps.go_backward(Some(JumpLocation::home()))
                .unwrap()
                .document_fingerprint,
            "sha-b"
        );
    }
}

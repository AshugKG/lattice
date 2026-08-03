#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReaderCommand {
    Open,
    Help,
    ScrollDown,
    ScrollUp,
    ScrollLeft,
    ScrollRight,
    HalfDown,
    HalfUp,
    DocumentStart,
    DocumentEnd,
    NextPage,
    PreviousPage,
    GoToPage(usize),
    ZoomIn,
    ZoomOut,
    FitWidth,
    FindToolbar,
    FindForward,
    FindBackward,
    FindNext,
    FindPrevious,
    CaptureMark,
    CancelMark,
    JumpBackward,
    JumpForward,
    ShowCommandPalette,
    ShowMarks,
    ShowHome,
    VerticalSplit,
    HorizontalSplit,
    CloseSplit,
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    Quit,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ShortcutModifiers {
    pub control: bool,
    pub command: bool,
}

#[derive(Debug, Default)]
pub struct ShortcutResolver {
    last_g: f64,
}

impl ShortcutResolver {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn resolve(
        &mut self,
        key: &str,
        modifiers: ShortcutModifiers,
        timestamp: f64,
    ) -> Option<ReaderCommand> {
        let normalized = key.to_lowercase();

        // Cmd bindings are intentionally ignored on the MuPDF port (Windows / cross-platform).
        if modifiers.command && !modifiers.control {
            return None;
        }

        if modifiers.control {
            return match normalized.as_str() {
                "o" => Some(ReaderCommand::JumpBackward),
                "i" => Some(ReaderCommand::JumpForward),
                "d" => Some(ReaderCommand::HalfDown),
                "u" => Some(ReaderCommand::HalfUp),
                "h" => Some(ReaderCommand::FocusLeft),
                "j" => Some(ReaderCommand::FocusDown),
                "k" => Some(ReaderCommand::FocusUp),
                "l" => Some(ReaderCommand::FocusRight),
                "f" => Some(ReaderCommand::FindToolbar),
                _ => None,
            };
        }

        if key == "\u{1b}" || key == "Escape" {
            return Some(ReaderCommand::CancelMark);
        }

        if key == "g" {
            let chord = timestamp - self.last_g < 0.65;
            self.last_g = timestamp;
            return if chord {
                Some(ReaderCommand::DocumentStart)
            } else {
                None
            };
        }

        match key {
            "o" => Some(ReaderCommand::Open),
            "j" => Some(ReaderCommand::ScrollDown),
            "k" => Some(ReaderCommand::ScrollUp),
            "h" => Some(ReaderCommand::ScrollLeft),
            "l" => Some(ReaderCommand::ScrollRight),
            "G" => Some(ReaderCommand::DocumentEnd),
            "]" => Some(ReaderCommand::NextPage),
            "[" => Some(ReaderCommand::PreviousPage),
            "+" | "=" => Some(ReaderCommand::ZoomIn),
            "-" => Some(ReaderCommand::ZoomOut),
            "0" => Some(ReaderCommand::FitWidth),
            "m" => Some(ReaderCommand::CaptureMark),
            "/" => Some(ReaderCommand::FindForward),
            "?" => Some(ReaderCommand::FindBackward),
            "n" => Some(ReaderCommand::FindNext),
            "N" => Some(ReaderCommand::FindPrevious),
            ":" => Some(ReaderCommand::ShowCommandPalette),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vim_chords_and_ctrl() {
        let mut resolver = ShortcutResolver::new();
        assert_eq!(resolver.resolve("g", ShortcutModifiers::default(), 1.0), None);
        assert_eq!(
            resolver.resolve("g", ShortcutModifiers::default(), 1.5),
            Some(ReaderCommand::DocumentStart)
        );
        assert_eq!(
            resolver.resolve("G", ShortcutModifiers::default(), 2.0),
            Some(ReaderCommand::DocumentEnd)
        );
        let ctrl = ShortcutModifiers {
            control: true,
            command: false,
        };
        assert_eq!(
            resolver.resolve("d", ctrl, 2.0),
            Some(ReaderCommand::HalfDown)
        );
        assert_eq!(
            resolver.resolve("f", ctrl, 2.1),
            Some(ReaderCommand::FindToolbar)
        );
        assert_eq!(
            resolver.resolve("o", ctrl, 2.2),
            Some(ReaderCommand::JumpBackward)
        );
        assert_eq!(
            resolver.resolve("/", ShortcutModifiers::default(), 3.0),
            Some(ReaderCommand::FindForward)
        );
        assert_eq!(
            resolver.resolve(":", ShortcutModifiers::default(), 4.0),
            Some(ReaderCommand::ShowCommandPalette)
        );
        // Cmd+O must not open.
        assert_eq!(
            resolver.resolve(
                "o",
                ShortcutModifiers {
                    control: false,
                    command: true,
                },
                5.0
            ),
            None
        );
    }
}

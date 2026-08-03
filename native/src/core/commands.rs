use super::ReaderCommand;

#[derive(Clone, Debug, PartialEq)]
pub struct CommandDescriptor {
    pub name: String,
    pub aliases: Vec<String>,
    pub summary: String,
    pub shortcut: Option<String>,
    pub action: ReaderCommand,
}

impl CommandDescriptor {
    pub fn new(
        name: &str,
        aliases: &[&str],
        summary: &str,
        shortcut: Option<&str>,
        action: ReaderCommand,
    ) -> Self {
        Self {
            name: name.into(),
            aliases: aliases.iter().map(|s| (*s).into()).collect(),
            summary: summary.into(),
            shortcut: shortcut.map(str::to_owned),
            action,
        }
    }
}

pub fn command_catalog() -> Vec<CommandDescriptor> {
    vec![
        CommandDescriptor::new("marks", &[], "List marks in this PDF", None, ReaderCommand::ShowMarks),
        CommandDescriptor::new(
            "home",
            &["recents"],
            "Show the recent PDFs home screen",
            Some(":home"),
            ReaderCommand::ShowHome,
        ),
        CommandDescriptor::new(
            "vsplit",
            &["vs"],
            "Duplicate the PDF side by side",
            None,
            ReaderCommand::VerticalSplit,
        ),
        CommandDescriptor::new(
            "hsplit",
            &["split", "sp"],
            "Duplicate the PDF top and bottom",
            None,
            ReaderCommand::HorizontalSplit,
        ),
        CommandDescriptor::new(
            "q",
            &["quit"],
            "Close the active view (home if last)",
            Some(":q"),
            ReaderCommand::CloseSplit,
        ),
        CommandDescriptor::new(
            "qa",
            &["quitall"],
            "Close all views and go home",
            Some(":qa"),
            ReaderCommand::Quit,
        ),
        CommandDescriptor::new("open", &["edit", "e"], "Open a PDF", Some("o"), ReaderCommand::Open),
        CommandDescriptor::new(
            "find",
            &["search"],
            "Search forward in this PDF",
            Some("/"),
            ReaderCommand::FindForward,
        ),
        CommandDescriptor::new("mark", &[], "Create a mark", Some("m"), ReaderCommand::CaptureMark),
        CommandDescriptor::new("back", &[], "Jump backward", Some("Ctrl+O"), ReaderCommand::JumpBackward),
        CommandDescriptor::new(
            "forward",
            &[],
            "Jump forward",
            Some("Ctrl+I"),
            ReaderCommand::JumpForward,
        ),
        CommandDescriptor::new(
            "first",
            &["top"],
            "Go to the first page",
            Some("gg"),
            ReaderCommand::DocumentStart,
        ),
        CommandDescriptor::new(
            "last",
            &["bottom"],
            "Go to the last page",
            Some("G"),
            ReaderCommand::DocumentEnd,
        ),
        CommandDescriptor::new(
            "previous",
            &["prev"],
            "Go to the previous page",
            Some("["),
            ReaderCommand::PreviousPage,
        ),
        CommandDescriptor::new("next", &[], "Go to the next page", Some("]"), ReaderCommand::NextPage),
        CommandDescriptor::new("up", &[], "Scroll up", Some("k"), ReaderCommand::ScrollUp),
        CommandDescriptor::new("down", &[], "Scroll down", Some("j"), ReaderCommand::ScrollDown),
        CommandDescriptor::new("left", &[], "Scroll left", Some("h"), ReaderCommand::ScrollLeft),
        CommandDescriptor::new("right", &[], "Scroll right", Some("l"), ReaderCommand::ScrollRight),
        CommandDescriptor::new(
            "halfup",
            &[],
            "Move half a screen up",
            Some("Ctrl+U"),
            ReaderCommand::HalfUp,
        ),
        CommandDescriptor::new(
            "halfdown",
            &[],
            "Move half a screen down",
            Some("Ctrl+D"),
            ReaderCommand::HalfDown,
        ),
        CommandDescriptor::new(
            "fit",
            &["fitwidth"],
            "Fit the PDF to the window",
            Some("0"),
            ReaderCommand::FitWidth,
        ),
        CommandDescriptor::new("zoomin", &[], "Zoom in", Some("+"), ReaderCommand::ZoomIn),
        CommandDescriptor::new("zoomout", &[], "Zoom out", Some("-"), ReaderCommand::ZoomOut),
        CommandDescriptor::new("help", &[], "Show keyboard shortcuts", Some(":help"), ReaderCommand::Help),
        CommandDescriptor::new(
            "cancel",
            &[],
            "Cancel mark capture or clear search",
            Some("Esc"),
            ReaderCommand::CancelMark,
        ),
    ]
}

fn normalized(query: &str) -> String {
    query
        .trim()
        .trim_start_matches(':')
        .to_lowercase()
}

pub fn page_number(query: &str) -> Option<usize> {
    let digits = query.trim().trim_matches(':');
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let page: usize = digits.parse().ok()?;
    (page >= 1).then_some(page)
}

pub fn go_to_page_command(page: usize) -> CommandDescriptor {
    CommandDescriptor::new(
        &page.to_string(),
        &[],
        &format!("Go to page {page}"),
        Some(&format!(":{page}")),
        ReaderCommand::GoToPage(page),
    )
}

pub fn exact_command(query: &str) -> Option<CommandDescriptor> {
    if let Some(page) = page_number(query) {
        return Some(go_to_page_command(page));
    }
    let query = normalized(query);
    command_catalog().into_iter().find(|command| {
        command.name == query || command.aliases.iter().any(|alias| alias == &query)
    })
}

fn fuzzy_score(query: &str, candidate: &str) -> Option<i32> {
    let query: Vec<char> = query.to_lowercase().chars().collect();
    let candidate: Vec<char> = candidate.to_lowercase().chars().collect();
    if query.is_empty() {
        return Some(0);
    }
    if query == candidate {
        return Some(10_000);
    }
    let mut query_index = 0;
    let mut score = 0;
    let mut previous_match: Option<usize> = None;
    for (index, character) in candidate.iter().enumerate() {
        if query_index >= query.len() {
            break;
        }
        if *character != query[query_index] {
            continue;
        }
        score += 10;
        if index == 0 {
            score += 25;
        }
        if previous_match.is_some_and(|prev| index == prev + 1) {
            score += 18;
        }
        if index > 0 {
            let prev = candidate[index - 1];
            if " -_/".contains(prev) {
                score += 12;
            }
        }
        previous_match = Some(index);
        query_index += 1;
    }
    if query_index != query.len() {
        return None;
    }
    Some(score - (candidate.len() as i32 - query.len() as i32).max(0))
}

pub fn match_commands(query: &str) -> Vec<CommandDescriptor> {
    if let Some(page) = page_number(query) {
        return vec![go_to_page_command(page)];
    }
    let query = normalized(query);
    let commands = command_catalog();
    if query.is_empty() {
        return commands;
    }
    let mut scored: Vec<_> = commands
        .into_iter()
        .filter_map(|command| {
            let mut candidates = vec![command.name.clone(), command.summary.clone()];
            candidates.extend(command.aliases.clone());
            if let Some(shortcut) = &command.shortcut {
                candidates.push(shortcut.clone());
            }
            let score = candidates
                .iter()
                .filter_map(|candidate| fuzzy_score(&query, candidate))
                .max()?;
            Some((command, score))
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.name.cmp(&b.0.name)));
    scored.into_iter().map(|(command, _)| command).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_and_fuzzy() {
        assert_eq!(page_number("12"), Some(12));
        assert_eq!(page_number(":12"), Some(12));
        assert!(exact_command("marks").is_some());
        let matches = match_commands("vs");
        assert!(matches.iter().any(|c| c.name == "vsplit"));
    }
}

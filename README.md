# Lattice

Lattice is a fast, local-first desktop PDF reader built for connected reading. This first milestone
opens PDFs through a file picker, drag-and-drop, or the operating system and pairs a visual toolbar
with Vim-style navigation.

The longer-term idea is to create **portals between text blocks**: durable, visual connections that
let one passage point into another document or location. The current renderer already retains the
PDF fingerprint, page index, and selectable text layer needed for that future anchor model; portal
creation and persistence are not implemented yet.

## What works

- Continuous, centered page flow powered by PDF.js's official viewer and rendering queue
- Selectable PDF.js text layers
- Fit-width, 25-400% zoom, and continuous macOS trackpad pinch preview with one deferred canvas redraw
- Password-protected PDFs and useful invalid-file errors
- Native Open dialog and Tauri file-drop handling
- `.pdf` file association with single-instance open handling
- Automatic light and dark appearance
- Local-only file access through a narrow Rust command and binary IPC

## Keyboard shortcuts

| Shortcut           | Action                   |
| ------------------ | ------------------------ |
| `o`, `Cmd/Ctrl+O`  | Open a PDF               |
| `j`, `k`           | Scroll down or up        |
| `h`, `l`           | Scroll left or right     |
| `Ctrl+d`, `Ctrl+u` | Move half a screen       |
| `gg`, `G`          | Jump to the start or end |
| `[`, `]`           | Previous or next page    |
| `+`, `-`           | Zoom in or out           |
| `0`                | Fit page width           |
| `?`                | Show shortcut help       |

Shortcuts are disabled while an input, text area, selector, or editable element has focus.

## Development

### Requirements

- [Bun](https://bun.sh/) 1.2 or newer
- Rust stable
- The [Tauri 2 platform prerequisites](https://v2.tauri.app/start/prerequisites/) for your operating
  system

```sh
bun install
bun run tauri dev
```

The browser-only frontend can be previewed with `bun run dev`, but opening local files requires the
Tauri desktop runtime.

### Checks

```sh
bun run check
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
bun run tauri build
```

To generate local PDF fixtures for visual QA, run `python3 scripts/create_qa_pdfs.py`. The password
for `lattice-protected.pdf` is `lattice`; generated files stay under the ignored `tmp/pdfs/`
directory.

## Architecture

- `src/App.tsx` owns document lifecycle, password callbacks, platform events, and global shortcuts.
- `src/components/PdfViewer.tsx` wraps PDF.js's official `PDFViewer`, rendering queue, text layers,
  viewport tracking, and cursor-anchored zoom.
- `src-tauri/src/lib.rs` validates and reads local PDFs, queues OS open events, and keeps the app
  single-instance.

PDF bytes are read locally and sent directly to PDF.js. Lattice does not upload documents or grant
the webview general filesystem access.

## Roadmap

1. Model a portal anchor with document fingerprint, page index, quoted text, and normalized bounds.
2. Add visual text-block selection and create a portal between two anchors.
3. Persist portals locally and render inbound/outbound portal indicators.
4. Add tabs, recents, restored reading positions, annotations, search, and command palettes.

## Status

Lattice is an early foundation, not yet a signed or notarized release. The repository CI checks the
frontend and Rust application on macOS, Windows, and Linux.

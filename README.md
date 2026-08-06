# Lattice

Lattice is a local-first macOS PDF reader for connected reading. Its document surface is Apple
PDFKit's native `PDFView`, embedded in an AppKit application. PDFKit owns rendering, text selection,
momentum scrolling, trackpad magnification, accessibility, and password handling; Lattice adds Vim
navigation and marks between passages above that surface.

The project is licensed under `AGPL-3.0-or-later`. PDFs remain on the local device.

## Current macOS application

- Native continuous-page `PDFView` with selectable text
- Unmodified macOS trackpad momentum and pinch-to-zoom behavior
- Open panel, drag-and-drop, command-line opening, and alternate PDF file-association metadata
- Password prompt for encrypted documents
- Native toolbar with page, zoom, Open, Fit, and shortcut controls
- Vim navigation implemented independently of rendering
- Persistent rectangle marks stored outside the PDF in Application Support
- Hover previews, exact mark teleports, cross-document path recovery, and source context-menu deletion
- Session-only Vim jump history with backward and forward traversal
- Exact per-document reading position and zoom restored across launches
- Native fuzzy Ex-command palette and a Vim-style `:marks` mark index
- Recent-PDF home screen with page thumbnails when Lattice launches with no document
- Independent two-pane PDF duplication through `:vsplit` and `:hsplit`, with `:q` / `:qa` and `Ctrl+hjkl`
- Active split pane owns keyboard navigation, half-page motion, and toolbar zoom
- In-PDF go-to links (chapters, figures, and similar) push onto the Vim jump list
- Stable mark anchors containing a SHA-256 document fingerprint, page index, optional extracted text,
  and normalized page-space bounds

### Run

Requirements are macOS 14 or newer, Xcode/Command Line Tools, Swift 6.2 or newer, and Bun.

```sh
bun install
bun run native -- /absolute/path/to/document.pdf
```

Open at a page with a highlight rectangle (used by LeetMath):

```sh
bun run open -- /absolute/path/to/document.pdf \
  --page-index 25 \
  --rect 0.08,0.40,0.84,0.18 \
  --label 1.2.A
```

`--page-index` is 0-based. `--rect` is normalized crop-box `x,y,width,height` in `[0,1]`.
Helper: [`scripts/lattice-open.sh`](scripts/lattice-open.sh).

You can also click Open or drop a PDF into the reader.

### Build an app bundle

```sh
bun run native:bundle
open macos/Lattice/build/Lattice.app
```

The generated `Info.plist` registers Lattice as an alternate PDF viewer. Signing, notarization, and
distribution are deferred.

## Cross-platform MuPDF reader (Windows / macOS / Linux)

`native/` is a Rust + egui + MuPDF port aimed at near feature parity with the macOS app. It uses the
OS wheel/trackpad scroll input (no custom smooth-scrolling), and prioritizes the marks UI.

### Requirements

- Rust toolchain (stable)
- On Windows: [MSVC Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) (C++ workload)
- Bun is optional; you can call Cargo directly

### Run

```sh
bun run native:mupdf -- /absolute/path/to/document.pdf
# or
cargo run --manifest-path native/Cargo.toml -- /absolute/path/to/document.pdf
```

```sh
bun run native:mupdf:build
bun run native:mupdf:test
```

### MuPDF keybind differences

| Shortcut | Action |
| -------- | ------ |
| `o`, Open button | Open a PDF (no Cmd/Ctrl+O open binding) |
| `Ctrl+F` | Toolbar search field |
| `/`, `?` | Vim-style search prompt |
| `Ctrl+O` / `Ctrl+I` | Jump backward / forward (unchanged) |

Marks, Vim navigation, `:commands`, splits, and jump list match the macOS table below.

### Persistence

Marks and reading state use the same JSON schemas as macOS. Paths:

- Windows: `%APPDATA%\Lattice\`
- macOS: `~/Library/Application Support/Lattice/` (via the platform data directory)
- Linux: `$XDG_DATA_HOME/Lattice/` (usually `~/.local/share/Lattice/`)

Files: `marks-v1.json`, `reading-state-v1.json`, `recents-v1.json`.

### Sharing a Windows `.exe` (no compile for your friend)

You are on macOS, so build the Windows binary in CI instead of locally:

1. Push this branch (or merge to `main`).
2. Open the GitHub Actions run **Windows MuPDF build**.
3. Download the **Lattice-windows-x64** artifact — it contains `lattice-native.exe`.
4. Send that `.exe` to your friend (zip is fine). They can double-click it; no Rust install needed.

You can also trigger a build manually: **Actions → Windows MuPDF build → Run workflow**.

First launch may need Windows Defender / SmartScreen “More info → Run anyway” because the binary is unsigned. If MSVC runtime DLLs are missing on a very old machine, install [Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).

### Manual QA checklist (Windows)

- [ ] Open PDF via Open button, `o`, drag-and-drop, and CLI path
- [ ] Wheel scroll and pinch/ctrl-zoom; `j/k`, `Ctrl+d/u`, `gg`/`G`, fit (`0`)
- [ ] Password prompt unlocks protected PDFs
- [ ] Marks: `m` drag source → drag dest; Ctrl-hover preview; Ctrl-click teleport; right-click delete; `:marks`
- [ ] Cross-document mark + locate-on-mismatch path recovery
- [ ] `Ctrl+F` toolbar search and `/` Vim search; `n`/`N` matches
- [ ] `:vsplit` / `:hsplit`, `Ctrl+hjkl`, `:q` / `:qa`
- [ ] Jump list `Ctrl+O` / `Ctrl+I` across PDF and home
- [ ] Reading position restores after relaunch; recents home lists files
- [ ] In-PDF go-to links navigate

## Keyboard shortcuts

| Shortcut           | Action                         |
| ------------------ | ------------------------------ |
| `o`, `Cmd+O`       | Open a PDF                     |
| `j`, `k`           | Scroll down or up              |
| `h`, `l`           | Scroll left or right           |
| `Ctrl+d`, `Ctrl+u` | Move half a screen             |
| `gg`, `G`          | Jump to the start or end       |
| `[`, `]`           | Previous or next page          |
| `+`, `-`           | Zoom in or out                 |
| `0`                | Fit width                      |
| `/`, `?`           | Search forward or backward     |
| `n`, `N`           | Next or previous search match  |
| `Cmd+F`            | Focus the toolbar search field |
| `m`                | Start rectangle mark capture   |
| `Ctrl+click`       | Follow a mark (source or destination) |
| `Ctrl+O`, `Ctrl+I` | Jump backward or forward       |
| `Escape`           | Cancel mark capture or clear search |
| `:`                | Fuzzy-find reader commands     |
| `:N`               | Go to page N (e.g. `:12`)      |
| `:marks`           | List marks in the current PDF  |
| `:home`            | Show the recent PDFs home screen |
| `:help`            | Show keyboard shortcuts        |
| `:q`               | Close the active view (home if last) |
| `:qa`              | Close all views and go home    |
| `Ctrl+h/j/k/l`     | Focus left/down/up/right split |

To create a mark, press `m` and drag a source rectangle. Navigate anywhere—including `:q` / `:home`
to the recents screen, or opening another PDF—and drag the destination rectangle. Hold Control while
hovering the source to preview its destination, then Control-click to teleport. Right-click the source
to delete the mark. At the destination, hold Control over its fainter rectangle to preview the
source; Control-clicking that rectangle returns to the source. Run `:marks` to list every mark source in the
current PDF; use `Ctrl+N` and `Ctrl+P` to move through command and mark lists.

Run `:vsplit` (or `:vs`) to duplicate the active PDF into side-by-side panes. Run `:hsplit`
(or `:split`/`:sp`) for top-and-bottom panes. The duplicate starts at the active pane's exact page,
viewport center, and zoom; afterward, both panes navigate independently. Running either command
again reorients the existing two-pane split and copies the active pane's view into the other pane.
Use `Ctrl+h/j/k/l` to move focus between panes (the active pane is outlined). `:q` closes the
active view; with one pane left it returns home. `:qa` always returns home. Clicking in-PDF links (chapters,
figures, and other go-to annotations) records the prior location on the jump list (`Ctrl+O` /
`Ctrl+I`). The jump list treats home like a location for the current Lattice session—`:q`, then
`Ctrl+O` / `Ctrl+I` moves between home and PDFs; quitting Lattice clears it.

Marks persist in
`~/Library/Application Support/Lattice/marks-v1.json`; the PDFs are never modified. The jump list
is intentionally reset when Lattice quits. Reading positions persist separately in
`~/Library/Application Support/Lattice/reading-state-v1.json`.

## Development

```sh
bun run native:build
bun run native:test
bun run check
```

To generate local PDF fixtures for visual QA, run `python3 scripts/create_qa_pdfs.py`. The password
for `lattice-protected.pdf` is `lattice`; generated files stay under the ignored `tmp/pdfs/`
directory.

## Architecture

### macOS (PDFKit)

- `macos/Lattice/Sources/Lattice/LatticeWindowController.swift` owns the AppKit window, `PDFView`, native
  toolbar, document lifecycle, and mark capture.
- `macos/Lattice/Sources/Lattice/LatticePDFView.swift` adds drag-and-drop and Vim event routing without
  intercepting trackpad scrolling or magnification.
- `macos/Lattice/Sources/LatticeCore/` contains renderer-independent Vim, mark persistence, and
  jump-list, command-search, and reading-state models.
- `macos/Lattice/Sources/Lattice/MarkOverlayView.swift` converts normalized mark geometry back
  into PDFKit coordinates and handles box capture and selective source-box interaction.
- `macos/Lattice/Sources/Lattice/MarkPreviewRenderer.swift` renders destination crops on a serial
  background queue and caches them by document, geometry, scale, and appearance.
- `macos/Lattice/Resources/Info.plist` contains the macOS bundle and PDF association metadata.

### MuPDF (`native/`)

- `native/src/engine.rs` — MuPDF document thread, tile rasterization, search, links, crops, passwords
- `native/src/core/` — Rust port of LatticeCore (marks, jumps, shortcuts, commands, recents, reading state)
- `native/src/app.rs` — egui shell: viewer, marks overlay, palette, dual search, splits, home
- `native/src/persist.rs` — platform data directory and SHA-256 fingerprints

## Roadmap

1. Add backlinks and a visual mark manager.
2. Add tabs, recents, annotations, and a command palette.
3. Add optional reading-state persistence.
4. Add signing, notarization, and releases.

## License

Lattice is licensed under the GNU Affero General Public License v3.0 or later. See `LICENSE`.

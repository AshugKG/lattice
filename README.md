# Lattice

Lattice is a local-first macOS PDF reader for connected reading. Its document surface is Apple
PDFKit's native `PDFView`, embedded in an AppKit application. PDFKit owns rendering, text selection,
momentum scrolling, trackpad magnification, accessibility, and password handling; Lattice adds Vim
navigation and portals between passages above that surface.

The project is licensed under `AGPL-3.0-or-later`. PDFs remain on the local device.

## Current macOS application

- Native continuous-page `PDFView` with selectable text
- Unmodified macOS trackpad momentum and pinch-to-zoom behavior
- Open panel, drag-and-drop, command-line opening, and alternate PDF file-association metadata
- Password prompt for encrypted documents
- Native toolbar with page, zoom, Open, Fit, and shortcut controls
- Vim navigation implemented independently of rendering
- Working session portal capture from two PDFKit text selections
- Stable portal anchors containing a SHA-256 document fingerprint, page index, quote, and normalized
  page-space bounds

### Run

Requirements are macOS 14 or newer, Xcode/Command Line Tools, Swift 6.2 or newer, and Bun.

```sh
bun install
bun run native -- /absolute/path/to/document.pdf
```

You can also click Open or drop a PDF into the reader.

### Build an app bundle

```sh
bun run native:bundle
open macos/Lattice/build/Lattice.app
```

The generated `Info.plist` registers Lattice as an alternate PDF viewer. Signing, notarization, and
distribution are deferred.

## Keyboard shortcuts

| Shortcut           | Action                                      |
| ------------------ | ------------------------------------------- |
| `o`, `Cmd+O`       | Open a PDF                                  |
| `j`, `k`           | Scroll down or up                           |
| `h`, `l`           | Scroll left or right                        |
| `Ctrl+d`, `Ctrl+u` | Move half a screen                          |
| `gg`, `G`          | Jump to the start or end                    |
| `[`, `]`           | Previous or next page                       |
| `+`, `-`           | Zoom in or out                              |
| `0`                | Fit width                                   |
| `Cmd+F`            | Search the document                         |
| `p`                | Capture source/destination portal endpoints |
| `?`                | Show shortcut help                          |

To create a session portal, select PDF text and press `p`, then select the destination text and
press `p` again. Lattice immediately draws both anchors in a transparent, click-through overlay;
persistence and portal navigation are the next portal milestones.

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

- `macos/Lattice/Sources/Lattice/LatticeWindowController.swift` owns the AppKit window, `PDFView`, native
  toolbar, document lifecycle, and portal capture.
- `macos/Lattice/Sources/Lattice/LatticePDFView.swift` adds drag-and-drop and Vim event routing without
  intercepting trackpad scrolling or magnification.
- `macos/Lattice/Sources/LatticeCore/` contains renderer-independent Vim and portal models.
- `macos/Lattice/Sources/Lattice/PortalOverlayView.swift` converts normalized portal geometry back
  into PDFKit coordinates and draws non-interactive passage indicators.
- `macos/Lattice/Resources/Info.plist` contains the macOS bundle and PDF association metadata.

The previous PDF.js/Tauri application under `src/` and `src-tauri/` is a frozen reference
implementation. It is no longer the product path and will not receive renderer or zoom tuning.

## Roadmap

1. Persist portals and reading state locally.
2. Make portal indicators interactive and add portal navigation and backlinks.
3. Add tabs, recents, and a command palette.
4. Add signing, notarization, and releases.

## License

Lattice is licensed under the GNU Affero General Public License v3.0 or later. See `LICENSE`.

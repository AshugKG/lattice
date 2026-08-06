#!/usr/bin/env bash
# Open a PDF in Lattice, optionally jumping to a page + normalized rect.
# Usage:
#   ./scripts/lattice-open.sh /path/book.pdf
#   ./scripts/lattice-open.sh /path/book.pdf --page-index 14 --rect 0.1,0.2,0.8,0.15 --label 3.1.3
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bun run --cwd "$ROOT" native -- "$@"

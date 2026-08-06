#!/usr/bin/env bash
# Open a PDF in Lattice, optionally jumping so a Y sits at the viewport top.
# Usage:
#   ./scripts/lattice-open.sh /path/book.pdf
#   ./scripts/lattice-open.sh /path/book.pdf --page-index 25 --top 0.42 --label 1.2.A
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bun run --cwd "$ROOT" native -- "$@"

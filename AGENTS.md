# Lattice agent notes

## Terminology: portals, not marks

In Lattice, connected passage rectangles are **portals**.

- Always say **portal** / **portals** in code names, UI copy, commands, docs, and commit messages.
- Prefer identifiers like `Portal`, `PortalAnchor`, `PortalRepository`, `:portals`, shortcut `p`.
- If the human says “mark” or “marks”, treat that as meaning **portal** / **portals** and still name things portals.
- Do not reintroduce `Mark` types, `:marks`, or the `m` capture shortcut unless migrating legacy on-disk data.

Legacy persistence may still read older `marks-v1.json` / `"marks"` JSON keys; new writes use `portals-v1.json` and `"portals"`.

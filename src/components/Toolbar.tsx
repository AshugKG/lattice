import type { DocumentDescriptor } from '../types';
import { FitIcon, HelpIcon, MinusIcon, OpenIcon, PlusIcon } from './Icons';

interface ToolbarProps {
  document: DocumentDescriptor | null;
  currentPage: number;
  scale: number;
  onOpen: () => void;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFit: () => void;
  onHelp: () => void;
}

export function Toolbar({
  document,
  currentPage,
  scale,
  onOpen,
  onZoomIn,
  onZoomOut,
  onFit,
  onHelp,
}: ToolbarProps) {
  return (
    <header className="toolbar">
      <div className="brand" aria-label="Lattice">
        <span className="brand-mark">L</span>
        <span className="brand-name">Lattice</span>
      </div>

      <div className="document-identity" title={document?.path}>
        <strong>{document?.name ?? 'No document open'}</strong>
        {document && (
          <span>
            {currentPage} / {document.pageCount}
          </span>
        )}
      </div>

      <nav className="toolbar-actions" aria-label="Reader controls">
        <button className="toolbar-button labeled" onClick={onOpen} title="Open PDF (O)">
          <OpenIcon />
          <span>Open</span>
        </button>
        <span className="toolbar-divider" />
        <button className="toolbar-button" onClick={onZoomOut} title="Zoom out (-)">
          <MinusIcon />
          <span className="sr-only">Zoom out</span>
        </button>
        <button className="zoom-readout" onClick={onFit} title="Fit width (0)">
          {Math.round(scale * 100)}%
        </button>
        <button className="toolbar-button" onClick={onZoomIn} title="Zoom in (+)">
          <PlusIcon />
          <span className="sr-only">Zoom in</span>
        </button>
        <button className="toolbar-button" onClick={onFit} title="Fit width (0)">
          <FitIcon />
          <span className="sr-only">Fit width</span>
        </button>
        <span className="toolbar-divider" />
        <button className="toolbar-button" onClick={onHelp} title="Keyboard shortcuts (?)">
          <HelpIcon />
          <span className="sr-only">Keyboard shortcuts</span>
        </button>
      </nav>
    </header>
  );
}

import { DocumentIcon, OpenIcon } from './Icons';

interface EmptyStateProps {
  onOpen: () => void;
  error?: { title: string; message: string };
}

export function EmptyState({ onOpen, error }: EmptyStateProps) {
  return (
    <main className="empty-state">
      <div className="empty-mark" aria-hidden="true">
        <DocumentIcon />
        <span />
      </div>
      <div className="empty-copy">
        <p className="eyebrow">Connected reading starts here</p>
        <h1>{error?.title ?? 'Open a PDF to begin'}</h1>
        <p>
          {error?.message ??
            'Drop a document anywhere in this window, or choose one from your computer.'}
        </p>
      </div>
      <button className="primary-button" onClick={onOpen}>
        <OpenIcon />
        Choose PDF
        <kbd>{navigator.platform.includes('Mac') ? '⌘ O' : 'Ctrl O'}</kbd>
      </button>
      <p className="privacy-note">Your documents stay on this device.</p>
    </main>
  );
}

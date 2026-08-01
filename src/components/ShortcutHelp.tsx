import { Modal } from './Modal';

const shortcuts = [
  ['o / ⌘O', 'Open PDF'],
  ['j / k', 'Scroll down / up'],
  ['h / l', 'Scroll left / right'],
  ['⌃d / ⌃u', 'Move half a screen'],
  ['gg / G', 'Go to start / end'],
  ['[ / ]', 'Previous / next page'],
  ['+ / -', 'Zoom in / out'],
  ['0', 'Fit page width'],
  ['?', 'Show shortcuts'],
];

export function ShortcutHelp({ onClose }: { onClose: () => void }) {
  return (
    <Modal title="Keyboard shortcuts" onClose={onClose}>
      <div className="shortcut-list">
        {shortcuts.map(([keys, label]) => (
          <div className="shortcut-row" key={keys}>
            <span>{label}</span>
            <kbd>{keys}</kbd>
          </div>
        ))}
      </div>
      <p className="modal-note">Shortcuts pause while you are typing into a field.</p>
    </Modal>
  );
}

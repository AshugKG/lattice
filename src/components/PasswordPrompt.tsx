import { useEffect, useRef, useState, type FormEvent } from 'react';

interface PasswordPromptProps {
  name: string;
  incorrect: boolean;
  onSubmit: (password: string) => void;
  onCancel: () => void;
}

export function PasswordPrompt({ name, incorrect, onSubmit, onCancel }: PasswordPromptProps) {
  const [password, setPassword] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => inputRef.current?.focus(), [incorrect]);

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault();
    if (password) onSubmit(password);
  };

  return (
    <div className="modal-backdrop">
      <form className="modal-card password-card" onSubmit={handleSubmit}>
        <p className="eyebrow">Protected document</p>
        <h2>Enter the PDF password</h2>
        <p className="password-file" title={name}>
          {name}
        </p>
        <label htmlFor="pdf-password">Password</label>
        <input
          ref={inputRef}
          id="pdf-password"
          type="password"
          value={password}
          aria-invalid={incorrect}
          onChange={(event) => setPassword(event.target.value)}
          placeholder="Document password"
        />
        {incorrect && <p className="field-error">That password did not unlock the document.</p>}
        <div className="dialog-actions">
          <button type="button" className="secondary-button" onClick={onCancel}>
            Cancel
          </button>
          <button className="primary-button compact" disabled={!password}>
            Unlock PDF
          </button>
        </div>
      </form>
    </div>
  );
}

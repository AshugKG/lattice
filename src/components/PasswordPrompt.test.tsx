import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { PasswordPrompt } from './PasswordPrompt';

describe('PasswordPrompt', () => {
  it('submits a document password', () => {
    const onSubmit = vi.fn();
    render(
      <PasswordPrompt
        name="protected.pdf"
        incorrect={false}
        onSubmit={onSubmit}
        onCancel={() => undefined}
      />,
    );
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'lattice' } });
    fireEvent.click(screen.getByRole('button', { name: 'Unlock PDF' }));
    expect(onSubmit).toHaveBeenCalledWith('lattice');
  });

  it('shows incorrect-password feedback', () => {
    render(
      <PasswordPrompt
        name="protected.pdf"
        incorrect
        onSubmit={() => undefined}
        onCancel={() => undefined}
      />,
    );
    expect(screen.getByText('That password did not unlock the document.')).toBeVisible();
    expect(screen.getByLabelText('Password')).toHaveAttribute('aria-invalid', 'true');
  });
});

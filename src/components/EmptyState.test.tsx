import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { EmptyState } from './EmptyState';

describe('EmptyState', () => {
  it('offers both opening paths and explains local privacy', () => {
    const onOpen = vi.fn();
    render(<EmptyState onOpen={onOpen} />);

    expect(screen.getByRole('heading', { name: 'Open a PDF to begin' })).toBeVisible();
    expect(screen.getByText('Your documents stay on this device.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: /Choose PDF/i }));
    expect(onOpen).toHaveBeenCalledOnce();
  });

  it('renders a recoverable open error', () => {
    render(
      <EmptyState
        onOpen={() => undefined}
        error={{ title: 'Invalid PDF', message: 'Choose another document.' }}
      />,
    );
    expect(screen.getByRole('heading', { name: 'Invalid PDF' })).toBeVisible();
    expect(screen.getByText('Choose another document.')).toBeVisible();
  });
});

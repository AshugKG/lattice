import { describe, expect, it } from 'vitest';
import { resolveShortcut } from './shortcuts';

describe('Vim shortcut resolver', () => {
  it('maps motion and zoom keys', () => {
    expect(resolveShortcut({ key: 'j' }, 1000, 0).command).toBe('scrollDown');
    expect(resolveShortcut({ key: 'u', ctrlKey: true }, 1000, 0).command).toBe('halfUp');
    expect(resolveShortcut({ key: '+' }, 1000, 0).command).toBe('zoomIn');
    expect(resolveShortcut({ key: '0' }, 1000, 0).command).toBe('fitWidth');
  });

  it('recognizes cross-platform open shortcuts', () => {
    expect(resolveShortcut({ key: 'o', metaKey: true }, 1000, 0).command).toBe('open');
    expect(resolveShortcut({ key: 'O', ctrlKey: true }, 1000, 0).command).toBe('open');
  });

  it('requires two timely g presses to jump to the start', () => {
    const first = resolveShortcut({ key: 'g' }, 1000, 0);
    expect(first.command).toBeNull();
    expect(resolveShortcut({ key: 'g' }, 1500, first.lastG).command).toBe('start');
    expect(resolveShortcut({ key: 'g' }, 1800, 1000).command).toBeNull();
  });
});

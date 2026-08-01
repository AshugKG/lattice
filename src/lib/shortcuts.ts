export type ShortcutCommand =
  | 'open'
  | 'help'
  | 'scrollDown'
  | 'scrollUp'
  | 'scrollLeft'
  | 'scrollRight'
  | 'halfDown'
  | 'halfUp'
  | 'start'
  | 'end'
  | 'nextPage'
  | 'previousPage'
  | 'zoomIn'
  | 'zoomOut'
  | 'fitWidth';

export interface ShortcutResult {
  command: ShortcutCommand | null;
  lastG: number;
}

export interface ShortcutInput {
  key: string;
  ctrlKey?: boolean;
  metaKey?: boolean;
}

export function resolveShortcut(
  input: ShortcutInput,
  now: number,
  previousG: number,
): ShortcutResult {
  const { key, ctrlKey = false, metaKey = false } = input;
  if ((metaKey || ctrlKey) && key.toLowerCase() === 'o') {
    return { command: 'open', lastG: previousG };
  }
  if (ctrlKey && key === 'd') return { command: 'halfDown', lastG: previousG };
  if (ctrlKey && key === 'u') return { command: 'halfUp', lastG: previousG };

  const commands: Record<string, ShortcutCommand> = {
    o: 'open',
    '?': 'help',
    j: 'scrollDown',
    k: 'scrollUp',
    h: 'scrollLeft',
    l: 'scrollRight',
    G: 'end',
    ']': 'nextPage',
    '[': 'previousPage',
    '+': 'zoomIn',
    '=': 'zoomIn',
    '-': 'zoomOut',
    '0': 'fitWidth',
  };
  if (key === 'g') {
    return {
      command: now - previousG < 650 ? 'start' : null,
      lastG: now,
    };
  }
  return { command: commands[key] ?? null, lastG: previousG };
}

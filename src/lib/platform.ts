import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { open } from '@tauri-apps/plugin-dialog';

const OPEN_PDF_EVENT = 'lattice://open-pdf';

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
  }
}

export function isDesktopRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

export async function pickPdf(): Promise<string | null> {
  if (!isDesktopRuntime()) return null;
  const selected = await open({
    multiple: false,
    directory: false,
    filters: [{ name: 'PDF document', extensions: ['pdf'] }],
  });
  return typeof selected === 'string' ? selected : null;
}

export async function readPdfBytes(path: string): Promise<Uint8Array> {
  const response = await invoke<ArrayBuffer | Uint8Array | number[]>('read_pdf', { path });
  if (response instanceof Uint8Array) return response;
  if (response instanceof ArrayBuffer) return new Uint8Array(response);
  return new Uint8Array(response);
}

export async function markFrontendReady(): Promise<string | null> {
  return invoke<string | null>('frontend_ready');
}

export async function listenForAssociatedPdf(handler: (path: string) => void): Promise<UnlistenFn> {
  return listen<string>(OPEN_PDF_EVENT, ({ payload }) => handler(payload));
}

export async function listenForPdfDrop(
  onDrop: (paths: string[]) => void,
  onHover: (active: boolean) => void,
): Promise<UnlistenFn> {
  return getCurrentWebview().onDragDropEvent(({ payload }) => {
    if (payload.type === 'drop') {
      onHover(false);
      onDrop(payload.paths);
    } else if (payload.type === 'over') {
      onHover(true);
    } else {
      onHover(false);
    }
  });
}

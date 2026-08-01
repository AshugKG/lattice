export const MIN_SCALE = 0.25;
export const MAX_SCALE = 4;
export const ZOOM_STEP = 0.15;

export function clampScale(scale: number): number {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
}

export function getSafeZoomOrigin(
  viewport: Pick<DOMRect, 'left' | 'top' | 'right' | 'bottom' | 'width' | 'height'>,
  requested: { x: number; y: number },
): { x: number; y: number } {
  const isInsideViewport =
    Number.isFinite(requested.x) &&
    Number.isFinite(requested.y) &&
    requested.x >= viewport.left &&
    requested.x <= viewport.right &&
    requested.y >= viewport.top &&
    requested.y <= viewport.bottom;
  if (isInsideViewport) return requested;
  return {
    x: viewport.left + viewport.width / 2,
    y: viewport.top + viewport.height / 2,
  };
}

export function getFileName(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts.at(-1) || 'Untitled.pdf';
}

export function isPdfPath(path: string): boolean {
  return /\.pdf$/i.test(path);
}

export function shouldIgnoreShortcut(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.isContentEditable ||
    target.tagName === 'INPUT' ||
    target.tagName === 'TEXTAREA' ||
    target.tagName === 'SELECT'
  );
}

export interface DisplayError {
  title: string;
  message: string;
}

export function describeOpenError(error: unknown): DisplayError {
  const fallback = {
    title: 'Could not open this PDF',
    message: 'Lattice could not read or render the selected document.',
  };
  if (!error || typeof error !== 'object') return fallback;

  const value = error as { code?: string; message?: string; name?: string };
  const messages: Record<string, DisplayError> = {
    notFound: {
      title: 'File not found',
      message: 'The document may have been moved or deleted.',
    },
    permissionDenied: {
      title: 'Permission denied',
      message: 'Lattice does not have permission to read this document.',
    },
    unsupportedType: {
      title: 'Not a PDF',
      message: 'Choose a file with the .pdf extension.',
    },
    invalidPdf: {
      title: 'Invalid PDF',
      message: 'This file does not contain a valid PDF document.',
    },
    InvalidPDFException: {
      title: 'Damaged PDF',
      message: 'PDF.js could not understand the structure of this document.',
    },
    MissingPDFException: {
      title: 'File not found',
      message: 'The document is no longer available.',
    },
  };
  return (
    messages[value.code ?? ''] ??
    messages[value.name ?? ''] ?? {
      ...fallback,
      message: value.message || fallback.message,
    }
  );
}

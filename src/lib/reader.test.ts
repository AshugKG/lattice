import { describe, expect, it } from 'vitest';
import {
  MAX_SCALE,
  MIN_SCALE,
  clampScale,
  describeOpenError,
  getCommittedScrollPosition,
  getFileName,
  getSafeZoomOrigin,
  isPdfPath,
  roundPdfJsScale,
  shouldIgnoreShortcut,
} from './reader';

describe('reader utilities', () => {
  it('clamps zoom to the supported range', () => {
    expect(clampScale(0.01)).toBe(MIN_SCALE);
    expect(clampScale(2)).toBe(2);
    expect(clampScale(8)).toBe(MAX_SCALE);
  });

  it('rounds preview zoom to the scale PDF.js will commit', () => {
    expect(roundPdfJsScale(1.234)).toBe(1.23);
    expect(roundPdfJsScale(4.8)).toBe(MAX_SCALE);
  });

  it('keeps the same document-space viewport point through a zoom commit', () => {
    const start = { left: 120, top: 5000 };
    const origin = { x: 400, y: 350 };
    const zoomedIn = getCommittedScrollPosition(start, origin, 1.25);
    const zoomedOut = getCommittedScrollPosition(start, origin, 0.8);

    expect(zoomedIn).toEqual({ left: 250, top: 6337.5 });
    expect(zoomedOut).toEqual({ left: 16, top: 3930 });
    expect((zoomedIn.top + origin.y) / 1.25).toBe(start.top + origin.y);
    expect((zoomedOut.top + origin.y) / 0.8).toBe(start.top + origin.y);
  });

  it('clamps committed scrolling at the document boundary', () => {
    expect(getCommittedScrollPosition({ left: 0, top: 0 }, { x: 400, y: 350 }, 0.5)).toEqual({
      left: 0,
      top: 0,
    });
  });

  it('falls back to the viewport center for invalid WebKit gesture coordinates', () => {
    const viewport = { left: 10, top: 60, right: 810, bottom: 660, width: 800, height: 600 };
    expect(getSafeZoomOrigin(viewport, { x: 0, y: 0 })).toEqual({ x: 410, y: 360 });
    expect(getSafeZoomOrigin(viewport, { x: 300, y: 240 })).toEqual({ x: 300, y: 240 });
  });

  it('recognizes PDF paths on each desktop platform', () => {
    expect(isPdfPath('/Users/test/Paper.PDF')).toBe(true);
    expect(isPdfPath('C:\\Papers\\paper.pdf')).toBe(true);
    expect(isPdfPath('/tmp/paper.pdf.txt')).toBe(false);
    expect(getFileName('C:\\Papers\\paper.pdf')).toBe('paper.pdf');
  });

  it('pauses shortcuts in editable elements', () => {
    expect(shouldIgnoreShortcut(document.createElement('input'))).toBe(true);
    expect(shouldIgnoreShortcut(document.createElement('textarea'))).toBe(true);
    expect(shouldIgnoreShortcut(document.createElement('div'))).toBe(false);
  });

  it('maps typed backend and PDF.js failures to useful messages', () => {
    expect(describeOpenError({ code: 'permissionDenied' }).title).toBe('Permission denied');
    expect(describeOpenError({ name: 'InvalidPDFException' }).title).toBe('Damaged PDF');
    expect(describeOpenError(new Error('worker failed')).message).toBe('worker failed');
  });
});

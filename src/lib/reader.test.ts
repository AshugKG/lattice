import { describe, expect, it } from 'vitest';
import {
  MAX_SCALE,
  MIN_SCALE,
  clampScale,
  describeOpenError,
  getFileName,
  getSafeZoomOrigin,
  isPdfPath,
  shouldIgnoreShortcut,
} from './reader';

describe('reader utilities', () => {
  it('clamps zoom to the supported range', () => {
    expect(clampScale(0.01)).toBe(MIN_SCALE);
    expect(clampScale(2)).toBe(2);
    expect(clampScale(8)).toBe(MAX_SCALE);
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

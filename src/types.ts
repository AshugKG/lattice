import type { PDFDocumentProxy } from 'pdfjs-dist';

export type DocumentSourceKind = 'picker' | 'drop' | 'association';

export interface DocumentSource {
  kind: DocumentSourceKind;
  path: string;
}

export interface DocumentDescriptor {
  fingerprint: string;
  path: string;
  name: string;
  pageCount: number;
}

export interface OpenDocument {
  descriptor: DocumentDescriptor;
  pdf: PDFDocumentProxy;
}

export type ReaderStatus =
  | { kind: 'empty' }
  | { kind: 'loading'; name: string }
  | { kind: 'password'; name: string; incorrect: boolean }
  | { kind: 'ready'; document: OpenDocument }
  | { kind: 'error'; title: string; message: string };

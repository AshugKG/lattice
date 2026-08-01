import { useCallback, useEffect, useRef, useState } from 'react';
import {
  getDocument,
  GlobalWorkerOptions,
  PasswordResponses,
  type PDFDocumentLoadingTask,
} from 'pdfjs-dist';
import { EmptyState } from './components/EmptyState';
import { PasswordPrompt } from './components/PasswordPrompt';
import { PdfViewer, type ViewerHandle } from './components/PdfViewer';
import { ShortcutHelp } from './components/ShortcutHelp';
import { Toolbar } from './components/Toolbar';
import {
  isDesktopRuntime,
  listenForAssociatedPdf,
  listenForPdfDrop,
  markFrontendReady,
  pickPdf,
  readPdfBytes,
} from './lib/platform';
import { describeOpenError, getFileName, isPdfPath, shouldIgnoreShortcut } from './lib/reader';
import { resolveShortcut } from './lib/shortcuts';
import type { DocumentSource, ReaderStatus } from './types';

GlobalWorkerOptions.workerSrc = new URL(
  'pdfjs-dist/build/pdf.worker.min.mjs',
  import.meta.url,
).toString();

type PasswordUpdater = (password: string) => void;

export function App() {
  const [status, setStatus] = useState<ReaderStatus>({ kind: 'empty' });
  const [scale, setScale] = useState(1);
  const [currentPage, setCurrentPage] = useState(1);
  const [helpOpen, setHelpOpen] = useState(false);
  const [dropActive, setDropActive] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const viewerRef = useRef<ViewerHandle>(null);
  const loadingTaskRef = useRef<PDFDocumentLoadingTask | null>(null);
  const passwordUpdaterRef = useRef<PasswordUpdater | null>(null);
  const lastGRef = useRef(0);

  const openDocument = useCallback(async (source: DocumentSource) => {
    const name = getFileName(source.path);
    setNotice(null);
    setCurrentPage(1);
    setStatus({ kind: 'loading', name });
    passwordUpdaterRef.current = null;
    await loadingTaskRef.current?.destroy();

    try {
      const bytes = await readPdfBytes(source.path);
      const loadingTask = getDocument({ data: bytes, disableAutoFetch: true });
      loadingTaskRef.current = loadingTask;
      loadingTask.onPassword = (updatePassword: PasswordUpdater, reason: number) => {
        passwordUpdaterRef.current = updatePassword;
        setStatus({
          kind: 'password',
          name,
          incorrect: reason === PasswordResponses.INCORRECT_PASSWORD,
        });
      };
      const pdf = await loadingTask.promise;
      const fingerprint = pdf.fingerprints[0] ?? `${name}:${pdf.numPages}`;
      setStatus({
        kind: 'ready',
        document: {
          pdf,
          descriptor: {
            fingerprint,
            path: source.path,
            name,
            pageCount: pdf.numPages,
          },
        },
      });
      document.title = `${name} - Lattice`;
    } catch (error) {
      if (loadingTaskRef.current?.destroyed) return;
      const displayError = describeOpenError(error);
      setStatus({ kind: 'error', ...displayError });
      document.title = 'Lattice';
    }
  }, []);

  const handleOpen = useCallback(async () => {
    if (!isDesktopRuntime()) {
      setStatus({
        kind: 'error',
        title: 'Desktop app required',
        message: 'Run “bun run tauri dev” to open local documents in Lattice.',
      });
      return;
    }
    const path = await pickPdf();
    if (path) void openDocument({ kind: 'picker', path });
  }, [openDocument]);

  useEffect(() => {
    if (!isDesktopRuntime()) return;
    let disposed = false;
    let unlistenAssociation: (() => void) | undefined;
    let unlistenDrop: (() => void) | undefined;

    void (async () => {
      unlistenAssociation = await listenForAssociatedPdf((path) => {
        void openDocument({ kind: 'association', path });
      });
      unlistenDrop = await listenForPdfDrop((paths) => {
        const pdfs = paths.filter(isPdfPath);
        if (pdfs.length === 0) {
          setNotice('Drop a file with the .pdf extension.');
          return;
        }
        if (paths.length > 1) setNotice('Opened the first PDF from the dropped files.');
        void openDocument({ kind: 'drop', path: pdfs[0] });
      }, setDropActive);
      const pendingPath = await markFrontendReady();
      if (pendingPath && !disposed) void openDocument({ kind: 'association', path: pendingPath });
    })();

    return () => {
      disposed = true;
      unlistenAssociation?.();
      unlistenDrop?.();
    };
  }, [openDocument]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (shouldIgnoreShortcut(event.target)) return;
      if (helpOpen && event.key !== 'Escape') return;

      const viewportHeight = window.innerHeight - 72;
      const shortcut = resolveShortcut(event, Date.now(), lastGRef.current);
      lastGRef.current = shortcut.lastG;
      if (!shortcut.command) return;

      if (shortcut.command === 'open') void handleOpen();
      else if (shortcut.command === 'help') setHelpOpen(true);
      else if (shortcut.command === 'scrollDown') viewerRef.current?.scrollBy(0, 88);
      else if (shortcut.command === 'scrollUp') viewerRef.current?.scrollBy(0, -88);
      else if (shortcut.command === 'scrollLeft') viewerRef.current?.scrollBy(-88, 0);
      else if (shortcut.command === 'scrollRight') viewerRef.current?.scrollBy(88, 0);
      else if (shortcut.command === 'halfDown') viewerRef.current?.scrollBy(0, viewportHeight / 2);
      else if (shortcut.command === 'halfUp') viewerRef.current?.scrollBy(0, -viewportHeight / 2);
      else if (shortcut.command === 'end') viewerRef.current?.scrollToEdge('end');
      else if (shortcut.command === 'start') viewerRef.current?.scrollToEdge('start');
      else if (shortcut.command === 'nextPage') viewerRef.current?.goToPage(currentPage + 1);
      else if (shortcut.command === 'previousPage') viewerRef.current?.goToPage(currentPage - 1);
      else if (shortcut.command === 'zoomIn') viewerRef.current?.zoomIn();
      else if (shortcut.command === 'zoomOut') viewerRef.current?.zoomOut();
      else if (shortcut.command === 'fitWidth') viewerRef.current?.fitWidth();
      event.preventDefault();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [currentPage, handleOpen, helpOpen]);

  useEffect(
    () => () => {
      void loadingTaskRef.current?.destroy();
    },
    [],
  );

  const descriptor = status.kind === 'ready' ? status.document.descriptor : null;

  return (
    <div className={`app-shell ${dropActive ? 'is-dropping' : ''}`}>
      <Toolbar
        document={descriptor}
        currentPage={currentPage}
        scale={scale}
        onOpen={() => void handleOpen()}
        onZoomIn={() => viewerRef.current?.zoomIn()}
        onZoomOut={() => viewerRef.current?.zoomOut()}
        onFit={() => viewerRef.current?.fitWidth()}
        onHelp={() => setHelpOpen(true)}
      />

      {status.kind === 'ready' && (
        <PdfViewer
          ref={viewerRef}
          pdf={status.document.pdf}
          onScaleChange={setScale}
          onCurrentPageChange={setCurrentPage}
        />
      )}
      {(status.kind === 'empty' || status.kind === 'error') && (
        <EmptyState
          onOpen={() => void handleOpen()}
          error={status.kind === 'error' ? status : undefined}
        />
      )}
      {status.kind === 'loading' && (
        <main className="loading-state" aria-live="polite">
          <span className="loading-orbit" />
          <p>Opening {status.name}</p>
          <span>Preparing pages and selectable text…</span>
        </main>
      )}
      {status.kind === 'password' && (
        <PasswordPrompt
          name={status.name}
          incorrect={status.incorrect}
          onSubmit={(password) => passwordUpdaterRef.current?.(password)}
          onCancel={() => {
            void loadingTaskRef.current?.destroy();
            setStatus({ kind: 'empty' });
          }}
        />
      )}
      {helpOpen && <ShortcutHelp onClose={() => setHelpOpen(false)} />}
      {dropActive && (
        <div className="drop-overlay">
          <div>
            <span>+</span>
            <strong>Drop PDF to open</strong>
          </div>
        </div>
      )}
      {notice && (
        <button className="notice" onClick={() => setNotice(null)} aria-live="polite">
          {notice}
        </button>
      )}
    </div>
  );
}

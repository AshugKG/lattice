import { forwardRef, useCallback, useImperativeHandle, useLayoutEffect, useRef } from 'react';
import type { PDFDocumentProxy } from 'pdfjs-dist';
import { EventBus, PDFLinkService, PDFViewer as PdfJsViewer } from 'pdfjs-dist/web/pdf_viewer.mjs';
import { clampScale, getSafeZoomOrigin } from '../lib/reader';

export interface ViewerHandle {
  scrollBy: (left: number, top: number) => void;
  scrollToEdge: (edge: 'start' | 'end') => void;
  goToPage: (page: number) => void;
  fitWidth: () => void;
  zoomIn: () => void;
  zoomOut: () => void;
}

interface PdfViewerProps {
  pdf: PDFDocumentProxy;
  onScaleChange: (scale: number) => void;
  onCurrentPageChange: (page: number) => void;
}

interface PdfJsViewerOptionsWithSignal {
  container: HTMLDivElement;
  viewer: HTMLDivElement;
  eventBus: EventBus;
  linkService: PDFLinkService;
  removePageBorders: boolean;
  supportsPinchToZoom: boolean;
  abortSignal: AbortSignal;
}

interface WebKitGestureEvent extends Event {
  clientX: number;
  clientY: number;
  scale: number;
}

interface ZoomSession {
  startScale: number;
  targetScale: number;
  originClient: [number, number];
  originElement: [number, number];
}

const WHEEL_GESTURE_SETTLE_DELAY = 140;
const FINAL_RENDER_DELAY = 180;

export const PdfViewer = forwardRef<ViewerHandle, PdfViewerProps>(function PdfViewer(
  { pdf, onScaleChange, onCurrentPageChange },
  ref,
) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const viewerElementRef = useRef<HTMLDivElement>(null);
  const viewerRef = useRef<PdfJsViewer | null>(null);
  const zoomSessionRef = useRef<ZoomSession | null>(null);
  const zoomFrameRef = useRef<number | null>(null);
  const wheelSettleTimerRef = useRef<number | null>(null);
  const nativeGestureActiveRef = useRef(false);

  const setScale = useCallback((nextScale: number, drawingDelay = -1, origin?: number[]) => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.currentScale <= 0) return;
    const target = clampScale(nextScale);
    viewer.updateScale({
      scaleFactor: target / viewer.currentScale,
      drawingDelay,
      origin,
    });
  }, []);

  const zoomBy = useCallback(
    (amount: number) => {
      const viewer = viewerRef.current;
      if (!viewer) return;
      setScale(viewer.currentScale + amount);
    },
    [setScale],
  );

  useImperativeHandle(
    ref,
    () => ({
      scrollBy(left, top) {
        viewportRef.current?.scrollBy({ left, top, behavior: 'smooth' });
      },
      scrollToEdge(edge) {
        const viewport = viewportRef.current;
        viewport?.scrollTo({
          top: edge === 'start' ? 0 : viewport.scrollHeight,
          behavior: 'smooth',
        });
      },
      goToPage(page) {
        const safePage = Math.max(1, Math.min(pdf.numPages, page));
        viewerRef.current?.scrollPageIntoView({ pageNumber: safePage });
      },
      fitWidth() {
        if (viewerRef.current) viewerRef.current.currentScaleValue = 'page-width';
      },
      zoomIn() {
        zoomBy(0.15);
      },
      zoomOut() {
        zoomBy(-0.15);
      },
    }),
    [pdf.numPages, zoomBy],
  );

  useLayoutEffect(() => {
    const container = viewportRef.current;
    const viewerElement = viewerElementRef.current;
    if (!container || !viewerElement) return;

    const abortController = new AbortController();
    const eventBus = new EventBus();
    const linkService = new PDFLinkService({ eventBus });
    const viewer = new PdfJsViewer({
      container,
      viewer: viewerElement,
      eventBus,
      linkService,
      removePageBorders: true,
      supportsPinchToZoom: true,
      abortSignal: abortController.signal,
    } as PdfJsViewerOptionsWithSignal);
    viewerRef.current = viewer;
    linkService.setViewer(viewer);

    const handlePagesInit = () => {
      viewer.currentScaleValue = 'page-width';
      onCurrentPageChange(1);
    };
    const handlePageChange = ({ pageNumber }: { pageNumber: number }) => {
      onCurrentPageChange(pageNumber);
    };
    const handleScaleChange = ({ scale }: { scale: number }) => {
      onScaleChange(scale);
    };

    eventBus.on('pagesinit', handlePagesInit);
    eventBus.on('pagechanging', handlePageChange);
    eventBus.on('scalechanging', handleScaleChange);

    const beginZoomSession = (clientX: number, clientY: number) => {
      if (zoomSessionRef.current) return zoomSessionRef.current;
      const safeOrigin = getSafeZoomOrigin(container.getBoundingClientRect(), {
        x: clientX,
        y: clientY,
      });
      const bounds = viewerElement.getBoundingClientRect();
      const session: ZoomSession = {
        startScale: viewer.currentScale,
        targetScale: viewer.currentScale,
        originClient: [safeOrigin.x, safeOrigin.y],
        originElement: [safeOrigin.x - bounds.left, safeOrigin.y - bounds.top],
      };
      zoomSessionRef.current = session;
      viewerElement.classList.add('is-gesture-zooming');
      viewerElement.style.transformOrigin = `${session.originElement[0]}px ${session.originElement[1]}px`;
      return session;
    };

    const scheduleZoomPreview = () => {
      if (zoomFrameRef.current !== null) return;
      zoomFrameRef.current = requestAnimationFrame(() => {
        zoomFrameRef.current = null;
        const session = zoomSessionRef.current;
        if (!session) return;
        viewerElement.style.transform = `scale(${session.targetScale / session.startScale})`;
        onScaleChange(session.targetScale);
      });
    };

    const commitZoomSession = () => {
      const session = zoomSessionRef.current;
      if (!session) return;
      zoomSessionRef.current = null;
      if (zoomFrameRef.current !== null) cancelAnimationFrame(zoomFrameRef.current);
      zoomFrameRef.current = null;
      viewerElement.classList.remove('is-gesture-zooming');
      viewerElement.style.removeProperty('transform');
      viewerElement.style.removeProperty('transform-origin');
      setScale(session.targetScale, FINAL_RENDER_DELAY, session.originClient);
    };

    const handleWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      if (nativeGestureActiveRef.current) return;

      const multiplier =
        event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? container.clientHeight : 1;
      const session = beginZoomSession(event.clientX, event.clientY);
      const exponent = Math.max(-0.16, Math.min(0.16, -event.deltaY * multiplier * 0.004));
      session.targetScale = clampScale(session.targetScale * Math.exp(exponent));
      scheduleZoomPreview();

      if (wheelSettleTimerRef.current !== null) clearTimeout(wheelSettleTimerRef.current);
      wheelSettleTimerRef.current = window.setTimeout(() => {
        wheelSettleTimerRef.current = null;
        commitZoomSession();
      }, WHEEL_GESTURE_SETTLE_DELAY);
    };
    const handleGestureStart = (event: Event) => {
      event.preventDefault();
      nativeGestureActiveRef.current = true;
      if (wheelSettleTimerRef.current !== null) clearTimeout(wheelSettleTimerRef.current);
      wheelSettleTimerRef.current = null;
      const gesture = event as WebKitGestureEvent;
      commitZoomSession();
      beginZoomSession(gesture.clientX, gesture.clientY);
    };
    const handleGestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as WebKitGestureEvent;
      const session = zoomSessionRef.current;
      if (!session) return;
      session.targetScale = clampScale(session.startScale * gesture.scale);
      scheduleZoomPreview();
    };
    const handleGestureEnd = (event: Event) => {
      event.preventDefault();
      nativeGestureActiveRef.current = false;
      commitZoomSession();
    };
    container.addEventListener('wheel', handleWheel, { passive: false });
    container.addEventListener('gesturestart', handleGestureStart, { passive: false });
    container.addEventListener('gesturechange', handleGestureChange, { passive: false });
    container.addEventListener('gestureend', handleGestureEnd, { passive: false });

    viewer.setDocument(pdf);
    linkService.setDocument(pdf);

    return () => {
      container.removeEventListener('wheel', handleWheel);
      container.removeEventListener('gesturestart', handleGestureStart);
      container.removeEventListener('gesturechange', handleGestureChange);
      container.removeEventListener('gestureend', handleGestureEnd);
      eventBus.off('pagesinit', handlePagesInit);
      eventBus.off('pagechanging', handlePageChange);
      eventBus.off('scalechanging', handleScaleChange);
      if (zoomFrameRef.current !== null) cancelAnimationFrame(zoomFrameRef.current);
      if (wheelSettleTimerRef.current !== null) clearTimeout(wheelSettleTimerRef.current);
      zoomFrameRef.current = null;
      wheelSettleTimerRef.current = null;
      viewerElement.classList.remove('is-gesture-zooming');
      viewerElement.style.removeProperty('transform');
      viewerElement.style.removeProperty('transform-origin');
      abortController.abort();
      viewer.setDocument(null as unknown as PDFDocumentProxy);
      linkService.setDocument(null);
      if (viewerRef.current === viewer) viewerRef.current = null;
    };
  }, [onCurrentPageChange, onScaleChange, pdf, setScale]);

  return (
    <div className="viewer-stage">
      <div ref={viewportRef} className="pdf-viewport" tabIndex={-1}>
        <div ref={viewerElementRef} className="pdfViewer" role="document" />
      </div>
    </div>
  );
});

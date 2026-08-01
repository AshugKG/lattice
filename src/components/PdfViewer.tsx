import { forwardRef, useCallback, useImperativeHandle, useLayoutEffect, useRef } from 'react';
import type { PDFDocumentProxy } from 'pdfjs-dist';
import { EventBus, PDFLinkService, PDFViewer as PdfJsViewer } from 'pdfjs-dist/web/pdf_viewer.mjs';
import {
  clampScale,
  getCommittedScrollPosition,
  getSafeZoomOrigin,
  roundPdfJsScale,
} from '../lib/reader';

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
  rawTargetScale: number;
  targetScale: number;
  startScroll: { left: number; top: number };
  originViewport: { x: number; y: number };
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
  const commitFrameRef = useRef<number | null>(null);
  const wheelSettleTimerRef = useRef<number | null>(null);
  const nativeGestureActiveRef = useRef(false);

  const setScale = useCallback((nextScale: number, drawingDelay = -1, origin?: number[]) => {
    const viewer = viewerRef.current;
    if (!viewer || viewer.currentScale <= 0) return;
    const target = roundPdfJsScale(nextScale);
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
      const viewportBounds = container.getBoundingClientRect();
      const session: ZoomSession = {
        startScale: viewer.currentScale,
        rawTargetScale: viewer.currentScale,
        targetScale: viewer.currentScale,
        startScroll: { left: container.scrollLeft, top: container.scrollTop },
        originViewport: {
          x: safeOrigin.x - viewportBounds.left,
          y: safeOrigin.y - viewportBounds.top,
        },
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
      if (!zoomSessionRef.current || commitFrameRef.current !== null) return;
      commitFrameRef.current = requestAnimationFrame(() => {
        commitFrameRef.current = null;
        const session = zoomSessionRef.current;
        if (!session) return;
        zoomSessionRef.current = null;
        if (zoomFrameRef.current !== null) cancelAnimationFrame(zoomFrameRef.current);
        zoomFrameRef.current = null;

        setScale(session.targetScale, FINAL_RENDER_DELAY);
        const scaleRatio = viewer.currentScale / session.startScale;
        const committedScroll = getCommittedScrollPosition(
          session.startScroll,
          session.originViewport,
          scaleRatio,
        );
        container.scrollLeft = committedScroll.left;
        container.scrollTop = committedScroll.top;
        viewerElement.classList.remove('is-gesture-zooming');
        viewerElement.style.removeProperty('transform');
        viewerElement.style.removeProperty('transform-origin');
        viewer.update();
      });
    };

    const cancelPendingCommit = () => {
      if (commitFrameRef.current === null) return;
      cancelAnimationFrame(commitFrameRef.current);
      commitFrameRef.current = null;
    };

    const handleWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      if (nativeGestureActiveRef.current) return;
      cancelPendingCommit();

      const multiplier =
        event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? container.clientHeight : 1;
      const session = beginZoomSession(event.clientX, event.clientY);
      const exponent = Math.max(-0.16, Math.min(0.16, -event.deltaY * multiplier * 0.004));
      session.rawTargetScale = clampScale(session.rawTargetScale * Math.exp(exponent));
      session.targetScale = roundPdfJsScale(session.rawTargetScale);
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
      cancelPendingCommit();
      if (wheelSettleTimerRef.current !== null) clearTimeout(wheelSettleTimerRef.current);
      wheelSettleTimerRef.current = null;
      const gesture = event as WebKitGestureEvent;
      beginZoomSession(gesture.clientX, gesture.clientY);
    };
    const handleGestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as WebKitGestureEvent;
      const session = zoomSessionRef.current;
      if (!session) return;
      session.rawTargetScale = clampScale(session.startScale * gesture.scale);
      session.targetScale = roundPdfJsScale(session.rawTargetScale);
      scheduleZoomPreview();
    };
    const handleGestureEnd = (event: Event) => {
      event.preventDefault();
      nativeGestureActiveRef.current = false;
      commitZoomSession();
    };
    const handleScrollDuringGesture = () => {
      const session = zoomSessionRef.current;
      if (!session || commitFrameRef.current !== null) return;
      if (container.scrollLeft !== session.startScroll.left) {
        container.scrollLeft = session.startScroll.left;
      }
      if (container.scrollTop !== session.startScroll.top) {
        container.scrollTop = session.startScroll.top;
      }
    };
    container.addEventListener('wheel', handleWheel, { passive: false });
    container.addEventListener('gesturestart', handleGestureStart, { passive: false });
    container.addEventListener('gesturechange', handleGestureChange, { passive: false });
    container.addEventListener('gestureend', handleGestureEnd, { passive: false });
    container.addEventListener('scroll', handleScrollDuringGesture);

    viewer.setDocument(pdf);
    linkService.setDocument(pdf);

    return () => {
      container.removeEventListener('wheel', handleWheel);
      container.removeEventListener('gesturestart', handleGestureStart);
      container.removeEventListener('gesturechange', handleGestureChange);
      container.removeEventListener('gestureend', handleGestureEnd);
      container.removeEventListener('scroll', handleScrollDuringGesture);
      eventBus.off('pagesinit', handlePagesInit);
      eventBus.off('pagechanging', handlePageChange);
      eventBus.off('scalechanging', handleScaleChange);
      if (zoomFrameRef.current !== null) cancelAnimationFrame(zoomFrameRef.current);
      if (commitFrameRef.current !== null) cancelAnimationFrame(commitFrameRef.current);
      if (wheelSettleTimerRef.current !== null) clearTimeout(wheelSettleTimerRef.current);
      zoomFrameRef.current = null;
      commitFrameRef.current = null;
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

"""Create local-only PDF fixtures used for visual Lattice smoke testing."""

from pathlib import Path

from pypdf import PdfReader, PdfWriter
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen.canvas import Canvas


OUTPUT = Path(__file__).resolve().parents[1] / "tmp" / "pdfs"


def draw_page(canvas: Canvas, page: int, total: int) -> None:
    width, height = A4
    canvas.setFillColor(HexColor("#172017"))
    canvas.rect(0, 0, width, height, fill=1, stroke=0)
    canvas.setFillColor(HexColor("#dfff72"))
    canvas.setFont("Helvetica-Bold", 11)
    canvas.drawString(54, height - 58, "LATTICE / READER QA")
    canvas.setFillColor(HexColor("#f2f4ee"))
    canvas.setFont("Helvetica-Bold", 30)
    canvas.drawString(54, height - 112, f"A connected page {page}")
    canvas.setFillColor(HexColor("#aeb5a8"))
    canvas.setFont("Helvetica", 11)
    text = canvas.beginText(54, height - 156)
    text.setLeading(18)
    for line in (
        "This selectable text exercises PDFKit rendering and selection alignment.",
        "Portals attach normalized geometry to snippet boxes like this one.",
        "Keyboard motion should remain smooth while native pages scroll.",
        "The document never leaves the local device.",
    ):
        text.textLine(line)
    canvas.drawText(text)
    canvas.setStrokeColor(HexColor("#435043"))
    canvas.line(54, 112, width - 54, 112)
    canvas.setFont("Helvetica", 9)
    canvas.drawString(54, 88, "Text-layer fixture")
    canvas.drawRightString(width - 54, 88, f"{page} / {total}")
    canvas.showPage()


def create_document(path: Path, page_count: int) -> None:
    canvas = Canvas(str(path), pagesize=A4)
    for page in range(1, page_count + 1):
        draw_page(canvas, page, page_count)
    canvas.save()


def create_protected(source: Path, target: Path) -> None:
    reader = PdfReader(source)
    writer = PdfWriter()
    writer.append_pages_from_reader(reader)
    writer.encrypt("lattice")
    with target.open("wb") as stream:
        writer.write(stream)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    text_pdf = OUTPUT / "lattice-text.pdf"
    create_document(text_pdf, 3)
    create_document(OUTPUT / "lattice-long.pdf", 24)
    create_protected(text_pdf, OUTPUT / "lattice-protected.pdf")
    print(f"Created QA PDFs in {OUTPUT}")


if __name__ == "__main__":
    main()

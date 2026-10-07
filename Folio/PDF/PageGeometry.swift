import PDFKit

/// Folio's "page space" is the page as the reader sees it: points, origin at
/// the top-left of the crop box, y pointing down, page rotation applied.
/// Ink, highlights and pins are all stored in page space, so they stay put
/// whatever size the page is displayed at.
///
/// PDFKit's own page space has y pointing up and is not rotated; this type
/// converts between the two.
struct PageGeometry {
    /// Size of the page in page space.
    let size: CGSize
    let cropBox: CGRect
    /// PDF page space -> rotated crop box space (y up, origin at 0,0).
    let pdfToBox: CGAffineTransform

    init(page: PDFPage) {
        self.init(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        let x0 = cropBox.minX, y0 = cropBox.minY
        let w = cropBox.width, h = cropBox.height
        // PDF /Rotate turns the page clockwise when displayed.
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            size = CGSize(width: h, height: w)
            pdfToBox = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -y0, ty: w + x0)
        case 180:
            size = CGSize(width: w, height: h)
            pdfToBox = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w + x0, ty: h + y0)
        case 270:
            size = CGSize(width: h, height: w)
            pdfToBox = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h + y0, ty: -x0)
        default:
            size = CGSize(width: w, height: h)
            pdfToBox = CGAffineTransform(translationX: -x0, y: -y0)
        }
    }

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// PDF page space -> Folio page space.
    func pagePoint(fromPDF point: CGPoint) -> CGPoint {
        let p = point.applying(pdfToBox)
        return CGPoint(x: p.x, y: size.height - p.y)
    }

    /// Folio page space -> PDF page space.
    func pdfPoint(fromPage point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: size.height - point.y).applying(pdfToBox.inverted())
    }

    func pageRect(fromPDF rect: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map(pagePoint(fromPDF:))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Sets up a y-down context (page space) so that drawing the PDF page in
    /// PDF coordinates lands in the right place. Call inside save/restore.
    func applyPDFTransform(to context: CGContext) {
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(pdfToBox)
        context.clip(to: cropBox)
    }
}

extension PDFPage {
    var geometry: PageGeometry { PageGeometry(page: self) }

    /// Text-snapping selection between two points given in Folio page space.
    func textSelection(from start: CGPoint, to end: CGPoint, geometry: PageGeometry) -> PDFSelection? {
        let a = geometry.pdfPoint(fromPage: start)
        let b = geometry.pdfPoint(fromPage: end)
        guard let selection = selection(from: a, to: b),
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }

    /// Line rectangles of a selection, in Folio page space.
    func lineRects(of selection: PDFSelection, geometry: PageGeometry) -> [CGRect] {
        selection.selectionsByLine()
            .map { geometry.pageRect(fromPDF: $0.bounds(for: self)) }
            .filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}

import PencilKit
import UIKit

// MARK: - Pin thumbnails

extension BookSession {
    /// Picture of a pinned note (paper + highlights + ink), rendered off the main thread.
    func snapshot(of pin: Pin, maxPixels: CGFloat) async -> UIImage? {
        let drawing = drawing(for: pin.surface)
        let rect = pin.rect
        switch pin.surface {
        case .page(let index):
            guard (0..<pageCount).contains(index) else { return nil }
            let highlights = annotations.highlights(onPage: index)
            let renderer = self.renderer
            return await Task.detached(priority: .utility) {
                renderer.snapshot(page: index, region: rect, drawing: drawing, highlights: highlights, maxPixels: maxPixels)
            }.value
        case .board(let id):
            let background = annotations.boards.first { $0.id == id }?.background ?? .plain
            return await Task.detached(priority: .utility) {
                PageRenderer.compose(region: rect, maxPixels: maxPixels, drawing: drawing, highlights: []) { context in
                    BoardPattern.draw(background, in: context, rect: rect)
                }
            }.value
        }
    }

    /// Small image of a whole page, for bookmark rows.
    func pageThumbnail(_ index: Int, width: CGFloat) async -> UIImage? {
        guard (0..<pageCount).contains(index) else { return nil }
        let renderer = self.renderer
        let scale = UITraitCollection.current.displayScale
        return await Task.detached(priority: .utility) {
            renderer.image(page: index, width: width, scale: scale)
        }.value
    }

    /// Writes a copy of the book with ink, highlights and pin numbers burned
    /// in, followed by the whiteboards. Returns the file URL.
    func exportAnnotatedPDF() async throws -> URL {
        flushPendingInk()
        let job = AnnotatedExport(
            title: title,
            renderer: renderer,
            pages: (0..<pageCount).map { index in
                AnnotatedExport.Page(
                    index: index,
                    drawing: pagesWithInk.contains(index) ? drawing(forPage: index) : PKDrawing(),
                    highlights: annotations.highlights(onPage: index),
                    pins: annotations.pins(on: .page(index))
                )
            },
            boards: annotations.boards.map { board in
                AnnotatedExport.Board(board: board, drawing: drawing(forBoard: board.id), pins: annotations.pins(on: .board(board.id)))
            }
        )
        return try await Task.detached(priority: .userInitiated) { try job.write() }.value
    }
}

// MARK: - Export

/// Everything needed to write the annotated PDF, captured on the main thread
/// so the actual rendering can run in the background.
struct AnnotatedExport {
    struct Page {
        let index: Int
        let drawing: PKDrawing
        let highlights: [Highlight]
        let pins: [Pin]
    }

    struct Board {
        let board: Whiteboard
        let drawing: PKDrawing
        let pins: [Pin]
    }

    let title: String
    let renderer: PageRenderer
    let pages: [Page]
    let boards: [Board]

    /// Whiteboards are cut into pages with the proportions of a letter page.
    private static let boardPageSize = CGSize(width: WhiteboardViewController.boardWidth, height: 1325)

    func write() throws -> URL {
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle) (annotated).pdf")
        try? FileManager.default.removeItem(at: url)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Folio"]
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)

        try pdf.writePDF(to: url) { context in
            for page in pages {
                let geometry = renderer.geometry(page.index)
                context.beginPage(withBounds: geometry.bounds, pageInfo: [:])
                let cg = context.cgContext
                renderer.drawPage(page.index, in: cg)
                HighlightPainter.paint(page.highlights, in: cg)
                Self.drawInk(page.drawing, in: geometry.bounds)
                Self.drawPinBadges(page.pins, in: geometry.bounds)
            }

            for item in boards {
                let inkBottom = item.drawing.bounds.isNull ? 0 : item.drawing.bounds.maxY
                let pageCount = max(1, Int(ceil((inkBottom + 40) / Self.boardPageSize.height)))
                for pageNumber in 0..<pageCount {
                    let region = CGRect(origin: CGPoint(x: 0, y: CGFloat(pageNumber) * Self.boardPageSize.height), size: Self.boardPageSize)
                    context.beginPage(withBounds: CGRect(origin: .zero, size: Self.boardPageSize), pageInfo: [:])
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.translateBy(x: 0, y: -region.minY)
                    BoardPattern.draw(item.board.background, in: cg, rect: region)
                    Self.drawInk(item.drawing, in: region)
                    Self.drawPinBadges(item.pins, in: region)
                    cg.restoreGState()
                    if pageNumber == 0 {
                        Self.drawBoardTitle(item.board.title)
                    }
                }
            }
        }
        return url
    }

    private static func drawInk(_ drawing: PKDrawing, in region: CGRect) {
        guard !drawing.strokes.isEmpty, drawing.bounds.intersects(region) else { return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: region, scale: 2.5)
        }
        image?.draw(in: region)
    }

    private static func drawPinBadges(_ pins: [Pin], in region: CGRect) {
        for pin in pins where pin.rect.intersects(region) {
            let text = NSAttributedString(string: "\(pin.number)", attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.white,
            ])
            let size = text.size()
            let diameter = max(18, size.width + 8)
            let center = CGPoint(x: max(region.minX + diameter / 2, pin.rect.minX), y: max(region.minY + diameter / 2, pin.rect.minY))
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - 9, width: diameter, height: 18)
            pin.color.uiColor.setFill()
            UIBezierPath(roundedRect: circle, cornerRadius: 9).fill()
            text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        }
    }

    private static func drawBoardTitle(_ title: String) {
        let text = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ])
        text.draw(at: CGPoint(x: 24, y: 20))
    }
}

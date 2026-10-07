import Combine
import PencilKit
import SwiftUI
import UIKit

/// A tall notebook page that grows as you write. It uses the same tools as
/// the book, and its handwriting can be pinned too.
final class WhiteboardViewController: NoteSurfaceViewController {
    static let boardWidth: CGFloat = 1024
    /// The paper pattern is drawn this tall once; only visible tiles are ever rendered.
    private static let maxBoardHeight: CGFloat = 60_000

    let boardID: UUID
    private var background: BoardBackground?
    private var backgroundView: TiledLayerView?
    private var boardHeight: CGFloat = 1400
    private var lastLayoutSize: CGSize = .zero

    init(session: BookSession, boardID: UUID) {
        self.boardID = boardID
        super.init(session: session)
    }

    override var surface: NoteSurface? { .board(boardID) }
    override var drawingSize: CGSize { CGSize(width: Self.boardWidth, height: boardHeight) }
    override var scrollsAtFitZoom: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Paper.page
        let drawing = session.drawing(forBoard: boardID)
        installCanvas(in: view, drawing: drawing)
        canvas.alwaysBounceVertical = true
        canvas.showsVerticalScrollIndicator = true
        boardHeight = Self.height(fitting: drawing, viewportHeight: 0)

        session.$annotations
            .map { [boardID] (annotations: BookAnnotations) -> BoardBackground in
                annotations.boards.first(where: { $0.id == boardID })?.background ?? .plain
            }
            .removeDuplicates()
            .sink { [weak self] background in self?.setBackground(background) }
            .store(in: &cancellables)

        session.$boardFocus
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.handle(request) }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 1, view.bounds.size != lastLayoutSize else { return }
        lastLayoutSize = view.bounds.size
        canvas.frame = view.bounds
        overlay.frame = view.bounds
        let fit = view.bounds.width / Self.boardWidth
        boardHeight = Self.height(fitting: canvas.drawing, viewportHeight: view.bounds.height / fit)
        configureZoom(fit: fit, maxFactor: 3)
    }

    /// Always leave at least a screenful of empty paper below the last stroke.
    private static func height(fitting drawing: PKDrawing, viewportHeight: CGFloat) -> CGFloat {
        let inkBottom = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
        return min(maxBoardHeight, max(viewportHeight, 1400, inkBottom + max(viewportHeight, 600)))
    }

    override func drawingDidChange(_ drawing: PKDrawing) {
        session.setDrawing(drawing, forBoard: boardID)
        let viewport = fitZoom > 0 ? view.bounds.height / fitZoom : 0
        let needed = Self.height(fitting: drawing, viewportHeight: viewport)
        if needed > boardHeight {
            boardHeight = needed
            layoutContent()
        }
    }

    private func setBackground(_ background: BoardBackground) {
        guard background != self.background else { return }
        self.background = background
        backgroundView?.removeFromSuperview()
        let view = TiledLayerView(size: CGSize(width: Self.boardWidth, height: Self.maxBoardHeight)) { context in
            BoardPattern.draw(background, in: context, rect: context.boundingBoxOfClipPath)
        }
        underlay.insertSubview(view, at: 0)
        backgroundView = view
    }

    private func handle(_ request: FocusRequest) {
        guard case .board(let id) = request.surface, id == boardID else { return }
        if session.boardFocus?.id == request.id { session.boardFocus = nil }
        guard let rect = request.rect else { return }
        view.layoutIfNeeded()
        let zoom = canvas.zoomScale
        let target = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        let maxOffset = max(0, canvas.contentSize.height - canvas.bounds.height)
        let offsetY = min(max(0, target.midY - canvas.bounds.height / 2), maxOffset)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: offsetY), animated: request.animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + (request.animated ? 0.4 : 0.05)) { [weak self] in
            self?.flash(rect)
        }
    }
}

/// Paper patterns for whiteboards.
enum BoardPattern {
    static let spacing: CGFloat = 32
    private static let lineColor = UIColor(red: 0.62, green: 0.74, blue: 0.86, alpha: 0.75).cgColor
    private static let marginColor = UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 0.55).cgColor
    private static let dotColor = UIColor(white: 0.55, alpha: 0.6).cgColor

    /// Draws the pattern for `rect` (board space). Thread-safe.
    static func draw(_ background: BoardBackground, in context: CGContext, rect: CGRect) {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        let firstRow = floor(rect.minY / spacing) * spacing
        let firstColumn = floor(rect.minX / spacing) * spacing

        switch background {
        case .plain:
            break
        case .lined:
            context.setStrokeColor(lineColor)
            context.setLineWidth(1)
            var y = max(firstRow, spacing * 3)
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
            let marginX: CGFloat = 96
            if rect.minX <= marginX && rect.maxX >= marginX {
                context.setStrokeColor(marginColor)
                context.move(to: CGPoint(x: marginX, y: rect.minY))
                context.addLine(to: CGPoint(x: marginX, y: rect.maxY))
                context.strokePath()
            }
        case .grid:
            context.setStrokeColor(lineColor)
            context.setLineWidth(0.75)
            var y = firstRow
            while y <= rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            var x = firstColumn
            while x <= rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += spacing
            }
            context.strokePath()
        case .dotted:
            context.setFillColor(dotColor)
            var y = firstRow
            while y <= rect.maxY {
                var x = firstColumn
                while x <= rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

struct WhiteboardCanvasView: UIViewControllerRepresentable {
    let session: BookSession
    let boardID: UUID

    func makeUIViewController(context: Context) -> WhiteboardViewController {
        WhiteboardViewController(session: session, boardID: boardID)
    }

    func updateUIViewController(_ uiViewController: WhiteboardViewController, context: Context) {}
}

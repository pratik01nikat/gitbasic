import PDFKit
import PencilKit
import UIKit

/// Which part of an open book a sheet is.
enum SheetSide {
    case single, left, right
}

enum Paper {
    static let page = UIColor.white
    /// Endpapers: the blank sheets inside the covers in two-page view.
    static let endpaper = UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
    /// What's behind the book.
    static let desk = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 0.89, green: 0.87, blue: 0.83, alpha: 1)
    }
}

/// One sheet of the book inside the page-curl controller.
final class PageViewController: NoteSurfaceViewController {
    /// Position in the page-curl sequence (includes blank endpapers in two-page view).
    let slot: Int
    /// The PDF page shown, or nil for a blank endpaper.
    let pageIndex: Int?
    let side: SheetSide

    private let geometry: PageGeometry
    private let pageImageView = UIImageView()
    private let highlightsView = HighlightsLayerView(frame: .zero)
    private var tiledView: TiledLayerView?
    private let edgeShade = EdgeShadeView(frame: .zero)
    private var lastLayoutSize: CGSize = .zero

    init(session: BookSession, slot: Int, pageIndex: Int?, side: SheetSide) {
        self.slot = slot
        self.pageIndex = pageIndex
        self.side = side
        self.geometry = pageIndex.map(session.renderer.geometry) ?? PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        super.init(session: session)
    }

    override var surface: NoteSurface? { pageIndex.map { .page($0) } }
    override var drawingSize: CGSize { geometry.size }
    override var supportsTextHighlight: Bool { pageIndex != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageIndex == nil ? Paper.endpaper : Paper.page

        if let pageIndex {
            pageImageView.frame = geometry.bounds
            pageImageView.contentMode = .scaleToFill
            underlay.addSubview(pageImageView)
            highlightsView.frame = geometry.bounds
            underlay.addSubview(highlightsView)
            installCanvas(in: view, drawing: session.drawing(forPage: pageIndex))
        }

        edgeShade.side = side
        edgeShade.isUserInteractionEnabled = false
        view.addSubview(edgeShade)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        edgeShade.frame = view.bounds
        guard let pageIndex, view.bounds.width > 1, view.bounds.size != lastLayoutSize else { return }
        lastLayoutSize = view.bounds.size

        let frame = Self.pageFrame(for: geometry, in: view.bounds, side: side)
        canvas.frame = frame
        overlay.frame = frame
        pageImageView.image = session.renderer.image(page: pageIndex, width: frame.width, scale: view.traitCollection.displayScale)
        configureZoom(fit: frame.width / geometry.size.width, maxFactor: 4)
    }

    /// Where the page sits on its sheet: fitted with a small margin and, in
    /// two-page view, pushed against the spine so the pages meet in the middle.
    static func pageFrame(for geometry: PageGeometry, in bounds: CGRect, side: SheetSide) -> CGRect {
        let outer: CGFloat = 14, spine: CGFloat = 0
        let insets: UIEdgeInsets
        switch side {
        case .single: insets = UIEdgeInsets(top: outer, left: outer, bottom: outer, right: outer)
        case .left: insets = UIEdgeInsets(top: outer, left: outer, bottom: outer, right: spine)
        case .right: insets = UIEdgeInsets(top: outer, left: spine, bottom: outer, right: outer)
        }
        let area = bounds.inset(by: insets)
        guard area.width > 0, area.height > 0, geometry.size.width > 0, geometry.size.height > 0 else { return .zero }
        let scale = min(area.width / geometry.size.width, area.height / geometry.size.height)
        let size = CGSize(width: floor(geometry.size.width * scale), height: floor(geometry.size.height * scale))
        let x: CGFloat
        switch side {
        case .single: x = area.midX - size.width / 2
        case .left: x = area.maxX - size.width
        case .right: x = area.minX
        }
        return CGRect(x: round(x), y: round(area.midY - size.height / 2), width: size.width, height: size.height)
    }

    // MARK: - Hooks

    override func annotationsDidChange(_ annotations: BookAnnotations, toolKind: ToolKind) {
        super.annotationsDidChange(annotations, toolKind: toolKind)
        guard let pageIndex else { return }
        highlightsView.setHighlights(annotations.highlights(onPage: pageIndex))
    }

    override func drawingDidChange(_ drawing: PKDrawing) {
        guard let pageIndex else { return }
        session.setDrawing(drawing, forPage: pageIndex)
    }

    override func zoomOrScrollDidChange() {
        // Add the sharp, tiled renderer the first time the page is zoomed.
        guard isZoomed, tiledView == nil, let pageIndex else { return }
        let renderer = session.renderer
        let tiled = TiledLayerView(size: geometry.size) { context in
            renderer.drawPage(pageIndex, in: context)
        }
        underlay.insertSubview(tiled, aboveSubview: pageImageView)
        tiledView = tiled
    }

    override func textHighlightPan(from start: CGPoint, to current: CGPoint, state: UIGestureRecognizer.State) {
        guard let pageIndex, let page = session.document.page(at: pageIndex) else { return }
        let selection = page.textSelection(from: start, to: current, geometry: geometry)
        let rects = selection.map { page.lineRects(of: $0, geometry: geometry) } ?? []

        switch state {
        case .began, .changed:
            highlightsView.setPreview(rects, color: session.tool.markColor.uiColor)
        case .ended:
            highlightsView.setPreview([], color: nil)
            if let selection, !rects.isEmpty {
                session.addHighlight(page: pageIndex, rects: rects, text: selection.string ?? "")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.showToast("No selectable text on this page. Use the Marker to highlight by hand.", symbol: "highlighter")
            }
        default:
            highlightsView.setPreview([], color: nil)
        }
    }

    override func textHighlightMenu(at point: CGPoint) -> UIMenu? {
        guard let highlight = highlightsView.highlight(at: point) else { return nil }
        let session = self.session
        let copy = UIAction(title: "Copy Text", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = highlight.text
        }
        let colors = MarkColor.allCases.map { color in
            UIAction(title: color.name, image: .swatch(color.uiColor), state: color == highlight.color ? .on : .off) { _ in
                session.setHighlightColor(highlight.id, color)
            }
        }
        let delete = UIAction(title: "Remove Highlight", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            session.deleteHighlight(highlight.id)
        }
        return UIMenu(children: [copy, UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: colors), delete])
    }
}

/// Soft shading along the spine edge of a sheet so open pages look bound.
final class EdgeShadeView: UIView {
    var side: SheetSide = .single {
        didSet { setNeedsLayout() }
    }

    private let gradient = CAGradientLayer()
    private let edgeLine = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(gradient)
        layer.addSublayer(edgeLine)
        edgeLine.backgroundColor = UIColor(white: 0, alpha: 0.10).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dark = UIColor(white: 0, alpha: 1)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        switch side {
        case .single:
            let width: CGFloat = 16
            gradient.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            gradient.colors = [dark.withAlphaComponent(0.10).cgColor, dark.withAlphaComponent(0).cgColor]
            edgeLine.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        case .left:
            let width: CGFloat = 40
            gradient.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            gradient.colors = [dark.withAlphaComponent(0).cgColor, dark.withAlphaComponent(0.06).cgColor, dark.withAlphaComponent(0.20).cgColor]
            gradient.locations = [0, 0.7, 1]
            edgeLine.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        case .right:
            let width: CGFloat = 40
            gradient.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            gradient.colors = [dark.withAlphaComponent(0.22).cgColor, dark.withAlphaComponent(0.06).cgColor, dark.withAlphaComponent(0).cgColor]
            gradient.locations = [0, 0.3, 1]
            edgeLine.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        }
        if side == .single { gradient.locations = nil }
        CATransaction.commit()
    }
}

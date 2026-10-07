import Combine
import PencilKit
import UIKit

/// Shared behaviour for anything you can write on: a book page or a whiteboard.
///
/// Layering inside the canvas (all in drawing space, scaled by the canvas zoom):
///
///     PKCanvasView (scrolls + zooms)
///       ├─ underlay      paper: PDF page / whiteboard pattern, highlights
///       └─ ink           PencilKit's own views
///     overlay            pin badges, selection rectangle, flashes (fixed size)
class NoteSurfaceViewController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    let session: BookSession
    let canvas = InkCanvasView(frame: .zero)
    let underlay = UIView()
    let overlay = SurfaceOverlayView(frame: .zero)
    var cancellables = Set<AnyCancellable>()

    /// Called when the canvas zooms in from (or back to) its fitted size.
    var onZoomStateChange: ((Bool) -> Void)?
    private(set) var isZoomed = false
    private(set) var fitZoom: CGFloat = 1

    private var isLoadingDrawing = false
    private var markStart: CGPoint?
    private var currentToolKind: ToolKind = .pen
    private var fingerDrawing = false
    private var savedMinimumScrollTouches: Int?
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private lazy var markPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMarkPan(_:)))
        pan.maximumNumberOfTouches = 1
        return pan
    }()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var pendingMenu: UIMenu?

    init(session: BookSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Subclass hooks

    /// The surface pins and ink belong to; nil for blank sheets.
    var surface: NoteSurface? { nil }
    /// Size of the drawing space (page size for pages).
    var drawingSize: CGSize { .zero }
    /// Whether the Highlight Text tool works here.
    var supportsTextHighlight: Bool { false }
    /// Whether the canvas scrolls even when not zoomed in (whiteboards do).
    var scrollsAtFitZoom: Bool { false }

    func drawingDidChange(_ drawing: PKDrawing) {}
    func textHighlightPan(from start: CGPoint, to current: CGPoint, state: UIGestureRecognizer.State) {}
    func textHighlightMenu(at point: CGPoint) -> UIMenu? { nil }
    func zoomOrScrollDidChange() {}

    func annotationsDidChange(_ annotations: BookAnnotations, toolKind: ToolKind) {
        guard let surface else { return }
        overlay.setPins(annotations.pins(on: surface), showsOutlines: toolKind == .pin)
    }

    // MARK: - Setup

    /// Adds the canvas and overlay to `container` and starts following the shared tool.
    func installCanvas(in container: UIView, drawing: PKDrawing) {
        canvas.delegate = self
        isLoadingDrawing = true
        canvas.drawing = drawing
        isLoadingDrawing = false

        underlay.isUserInteractionEnabled = false
        underlay.backgroundColor = .clear
        canvas.insertSubview(underlay, at: 0)
        container.addSubview(canvas)
        container.addSubview(overlay)
        overlay.convert = { [weak self] rect in
            guard let self else { return rect }
            return self.underlay.convert(rect, to: self.overlay)
        }

        tapGesture.delegate = self
        markPan.delegate = self
        canvas.addGestureRecognizer(tapGesture)
        canvas.addGestureRecognizer(markPan)
        canvas.addInteraction(editMenu)

        session.$tool.combineLatest(session.$fingerDrawing)
            .sink { [weak self] tool, finger in self?.apply(tool: tool, fingerDrawing: finger) }
            .store(in: &cancellables)
        session.$annotations.combineLatest(session.$tool.map(\.kind).removeDuplicates())
            .sink { [weak self] annotations, kind in self?.annotationsDidChange(annotations, toolKind: kind) }
            .store(in: &cancellables)
    }

    private func apply(tool: ToolState, fingerDrawing: Bool) {
        currentToolKind = tool.kind
        self.fingerDrawing = fingerDrawing
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if let pencilKitTool = tool.pencilKitTool, surface != nil {
            canvas.tool = pencilKitTool
            canvas.drawingGestureRecognizer.isEnabled = true
        } else {
            canvas.drawingGestureRecognizer.isEnabled = false
        }
        updateInteraction()
    }

    /// Decides who gets single-finger drags: the page curl, scrolling, or the
    /// Pin / Highlight Text tools.
    private func updateInteraction() {
        let captures = currentToolKind == .pin || (currentToolKind == .textHighlight && supportsTextHighlight)
        let canScroll = scrollsAtFitZoom || isZoomed
        // On a surface that scrolls, fingers keep scrolling and Apple Pencil
        // marks, unless finger drawing is on.
        let fingerMarks = captures && (!canScroll || fingerDrawing)

        tapGesture.isEnabled = captures
        markPan.isEnabled = captures
        let touchTypes: [UITouch.TouchType] = fingerMarks ? [.direct, .pencil] : [.pencil]
        markPan.allowedTouchTypes = touchTypes.map { NSNumber(value: $0.rawValue) }
        if !captures { overlay.setSelection(nil) }

        // At the fitted size a page has nothing to scroll, and leaving scrolling
        // off lets single-finger drags reach the page curl.
        canvas.isScrollEnabled = canScroll

        // When one finger marks on a scrollable surface, scroll with two.
        if captures && canScroll && fingerMarks {
            if savedMinimumScrollTouches == nil {
                savedMinimumScrollTouches = canvas.panGestureRecognizer.minimumNumberOfTouches
            }
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        } else if let saved = savedMinimumScrollTouches {
            canvas.panGestureRecognizer.minimumNumberOfTouches = saved
            savedMinimumScrollTouches = nil
        }
    }

    // MARK: - Zoom

    /// Fits the drawing to the canvas width and resets zoom.
    func configureZoom(fit: CGFloat, maxFactor: CGFloat) {
        guard fit.isFinite, fit > 0 else { return }
        fitZoom = fit
        canvas.maximumZoomScale = fit * maxFactor
        canvas.minimumZoomScale = fit
        canvas.zoomScale = fit
        canvas.contentOffset = .zero
        layoutContent()
        setZoomed(false)
    }

    /// Keeps the underlay and content size in step with the canvas zoom.
    func layoutContent() {
        let zoom = canvas.zoomScale
        let size = drawingSize
        underlay.bounds = CGRect(origin: .zero, size: size)
        underlay.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        underlay.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        canvas.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        overlay.relayout()
    }

    private func setZoomed(_ zoomed: Bool) {
        guard zoomed != isZoomed else { return }
        isZoomed = zoomed
        updateInteraction()
        onZoomStateChange?(zoomed)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutContent()
        setZoomed(canvas.zoomScale > fitZoom * 1.02)
        zoomOrScrollDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        overlay.relayout()
        zoomOrScrollDidChange()
    }

    // MARK: - Ink

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoadingDrawing else { return }
        session.activeCanvas = canvas
        drawingDidChange(canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        session.activeCanvas = canvas
    }

    /// Replaces the ink without reporting it as a user edit.
    func loadDrawing(_ drawing: PKDrawing) {
        isLoadingDrawing = true
        canvas.drawing = drawing
        isLoadingDrawing = false
    }

    // MARK: - Pins & text highlight gestures

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tapGesture || gestureRecognizer === markPan else { return true }
        return currentToolKind == .pin || (currentToolKind == .textHighlight && supportsTextHighlight)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: underlay)
        let menuPoint = gesture.location(in: canvas)
        switch currentToolKind {
        case .pin:
            if let pin = overlay.pin(atBadgePoint: gesture.location(in: overlay)) {
                presentMenu(pinMenu(for: pin), at: menuPoint)
            } else {
                createPin(near: point)
            }
        case .textHighlight:
            if let menu = textHighlightMenu(at: point) {
                presentMenu(menu, at: menuPoint)
            }
        default:
            break
        }
    }

    @objc private func handleMarkPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: underlay)
        if gesture.state == .began {
            let translation = gesture.translation(in: underlay)
            markStart = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        }
        guard let start = markStart else { return }
        switch currentToolKind {
        case .pin:
            pinDrag(from: start, to: point, state: gesture.state)
        case .textHighlight:
            textHighlightPan(from: start, to: point, state: gesture.state)
        default:
            break
        }
        if [.ended, .cancelled, .failed].contains(gesture.state) {
            markStart = nil
        }
    }

    private var drawingBounds: CGRect { CGRect(origin: .zero, size: drawingSize) }

    private func createPin(near point: CGPoint) {
        guard let surface, drawingBounds.contains(point) else { return }
        let rect = StrokeClustering.noteBounds(around: point, in: canvas.drawing)?.intersection(drawingBounds)
            ?? StrokeClustering.defaultRect(at: point, within: drawingBounds)
        let pin = session.addPin(on: surface, rect: rect)
        overlay.flash(rect, color: pin.color.uiColor)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func pinDrag(from start: CGPoint, to current: CGPoint, state: UIGestureRecognizer.State) {
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
            .intersection(drawingBounds)
        switch state {
        case .began, .changed:
            overlay.setSelection(rect.isNull ? nil : rect)
        case .ended:
            overlay.setSelection(nil)
            guard let surface, !rect.isNull, rect.width >= 16, rect.height >= 16 else { return }
            let pin = session.addPin(on: surface, rect: rect)
            overlay.flash(rect, color: pin.color.uiColor)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default:
            overlay.setSelection(nil)
        }
    }

    // MARK: - Menus

    func presentMenu(_ menu: UIMenu, at point: CGPoint) {
        pendingMenu = menu
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        pendingMenu
    }

    private func pinMenu(for pin: Pin) -> UIMenu {
        let rename = UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.promptRename(pin)
        }
        let colors = UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: PinColor.allCases.map { color in
            UIAction(title: color.name, image: .swatch(color.uiColor), state: color == pin.color ? .on : .off) { [weak self] _ in
                self?.session.setPinColor(pin.id, color)
            }
        })
        let delete = UIAction(title: "Delete Pin", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.session.deletePin(pin.id)
        }
        return UIMenu(title: "\(pin.number). \(pin.title)", children: [rename, colors, delete])
    }

    private func promptRename(_ pin: Pin) {
        let alert = UIAlertController(title: "Rename Note \(pin.number)", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = pin.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            self?.session.renamePin(pin.id, to: alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    // MARK: - Focus

    /// Flashes a region (drawing space) so the reader can spot it.
    func flash(_ rect: CGRect) {
        overlay.flash(rect, color: view.tintColor ?? .systemBlue)
    }
}

extension UIImage {
    /// Small round color swatch for menus.
    static func swatch(_ color: UIColor, diameter: CGFloat = 18) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

import UIKit

/// Sits above the ink and shows numbered pin badges, the dashed rectangle
/// while dragging out a pin, and the "here it is" flash after navigating.
/// Badges keep a constant size whatever the zoom level.
final class SurfaceOverlayView: UIView {
    /// Converts a rect in drawing space into this view's coordinates.
    var convert: ((CGRect) -> CGRect)?

    private var pins: [Pin] = []
    private var showsOutlines = false
    private var badges: [UUID: PinBadgeView] = [:]
    private var outlines: [UUID: CAShapeLayer] = [:]
    private let selectionLayer = CAShapeLayer()
    private var selectionRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true

        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(selectionLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    func setPins(_ pins: [Pin], showsOutlines: Bool) {
        self.pins = pins
        self.showsOutlines = showsOutlines
        let ids = Set(pins.map(\.id))
        for (id, badge) in badges where !ids.contains(id) {
            badge.removeFromSuperview()
            badges[id] = nil
        }
        for (id, outline) in outlines where !ids.contains(id) {
            outline.removeFromSuperlayer()
            outlines[id] = nil
        }
        for pin in pins {
            let badge: PinBadgeView
            if let existing = badges[pin.id] {
                badge = existing
            } else {
                badge = PinBadgeView(frame: .zero)
                addSubview(badge)
                badges[pin.id] = badge
            }
            badge.configure(number: pin.number, color: pin.color.uiColor)

            let outline: CAShapeLayer
            if let existing = outlines[pin.id] {
                outline = existing
            } else {
                outline = CAShapeLayer()
                outline.fillColor = UIColor.clear.cgColor
                outline.lineWidth = 1.5
                outline.lineDashPattern = [5, 4]
                layer.insertSublayer(outline, below: selectionLayer)
                outlines[pin.id] = outline
            }
            outline.strokeColor = pin.color.uiColor.withAlphaComponent(0.8).cgColor
        }
        relayout()
    }

    func setSelection(_ rect: CGRect?) {
        selectionRect = rect
        relayout()
    }

    func relayout() {
        guard let convert else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let safe = bounds.insetBy(dx: 14, dy: 14)
        for pin in pins {
            let rect = convert(pin.rect)
            if let badge = badges[pin.id] {
                badge.sizeToFit()
                let x = min(max(rect.minX, safe.minX), max(safe.maxX, safe.minX))
                let y = min(max(rect.minY, safe.minY), max(safe.maxY, safe.minY))
                badge.center = CGPoint(x: x, y: y)
            }
            if let outline = outlines[pin.id] {
                outline.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
                outline.isHidden = !showsOutlines
            }
        }
        if let selectionRect {
            selectionLayer.path = UIBezierPath(roundedRect: convert(selectionRect), cornerRadius: 6).cgPath
            selectionLayer.isHidden = false
        } else {
            selectionLayer.path = nil
            selectionLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// The pin whose badge is under `point` (in this view's coordinates).
    func pin(atBadgePoint point: CGPoint) -> Pin? {
        pins.last { pin in
            guard let badge = badges[pin.id] else { return false }
            return badge.frame.insetBy(dx: -10, dy: -10).contains(point)
        }
    }

    /// Pulses a ring around `rect` (drawing space) to show where a note is.
    func flash(_ rect: CGRect, color: UIColor) {
        guard let convert else { return }
        let target = convert(rect).insetBy(dx: -8, dy: -8)
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(roundedRect: target, cornerRadius: 10).cgPath
        ring.fillColor = color.withAlphaComponent(0.10).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        layer.addSublayer(ring)

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0.25, 1, 0.25, 1, 0]
        pulse.keyTimes = [0, 0.12, 0.3, 0.45, 0.6, 0.8, 1]
        pulse.duration = 2.0
        pulse.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(pulse, forKey: "flash")
        CATransaction.commit()
    }
}

/// Round numbered badge for a pin.
final class PinBadgeView: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        textColor = .white
        font = .systemFont(ofSize: 13, weight: .bold)
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(number: Int, color: UIColor) {
        text = "\(number)"
        layer.backgroundColor = color.cgColor
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = super.sizeThatFits(size).width
        return CGSize(width: max(26, textWidth + 14), height: 26)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// Text highlights, drawn in page space inside the zooming content so they
/// stay attached to the words at every zoom level.
final class HighlightsLayerView: UIView {
    private(set) var highlights: [Highlight] = []
    private var layers: [UUID: CAShapeLayer] = [:]
    private let previewLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHighlights(_ highlights: [Highlight]) {
        guard highlights != self.highlights else { return }
        self.highlights = highlights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ids = Set(highlights.map(\.id))
        for (id, shape) in layers where !ids.contains(id) {
            shape.removeFromSuperlayer()
            layers[id] = nil
        }
        for highlight in highlights {
            let shape: CAShapeLayer
            if let existing = layers[highlight.id] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                layer.insertSublayer(shape, below: previewLayer)
                layers[highlight.id] = shape
            }
            shape.path = Self.path(for: highlight.rects)
            shape.fillColor = highlight.color.uiColor.withAlphaComponent(HighlightPainter.alpha).cgColor
        }
        CATransaction.commit()
    }

    func setPreview(_ rects: [CGRect], color: UIColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.path = rects.isEmpty ? nil : Self.path(for: rects)
        previewLayer.fillColor = (color ?? .clear).withAlphaComponent(HighlightPainter.alpha).cgColor
        CATransaction.commit()
    }

    func highlight(at point: CGPoint) -> Highlight? {
        highlights.last { $0.rects.contains { $0.insetBy(dx: -4, dy: -4).contains(point) } }
    }

    private static func path(for rects: [CGRect]) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            path.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -0.5), cornerRadius: 2).cgPath)
        }
        return path
    }
}

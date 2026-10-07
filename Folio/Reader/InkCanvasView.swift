import PencilKit
import UIKit

/// PKCanvasView with its own undo stack, so undo on one page never reaches
/// into another page (or a whiteboard), and with ink colors locked to light
/// appearance so black ink stays black on white paper in Dark Mode.
final class InkCanvasView: PKCanvasView {
    private let canvasUndoManager = UndoManager()

    override var undoManager: UndoManager? { canvasUndoManager }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        backgroundColor = .clear
        isOpaque = false
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        isScrollEnabled = false
        bouncesZoom = true
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        canvasUndoManager.removeAllActions()
    }
}

/// Finds the block of handwriting around a point, so a single tap with the
/// Pin tool can pin a whole note.
enum StrokeClustering {
    /// Returns the bounds of the strokes near `point`, grown to include
    /// neighbouring strokes (words on the same line and lines of the same
    /// paragraph), or nil if there is no ink near the point.
    static func noteBounds(around point: CGPoint, in drawing: PKDrawing) -> CGRect? {
        let bounds = drawing.strokes.map(\.renderBounds).filter { !$0.isNull && !$0.isEmpty }
        guard !bounds.isEmpty else { return nil }

        let probe = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
        var included = Set<Int>()
        var cluster = CGRect.null
        for (index, rect) in bounds.enumerated() where rect.intersects(probe) {
            included.insert(index)
            cluster = cluster.union(rect)
        }
        guard !cluster.isNull else { return nil }

        // Words are further apart horizontally than lines are vertically.
        let horizontalGap: CGFloat = 40
        let verticalGap: CGFloat = 20
        var grew = true
        while grew {
            grew = false
            let reach = cluster.insetBy(dx: -horizontalGap, dy: -verticalGap)
            for (index, rect) in bounds.enumerated() where !included.contains(index) && rect.intersects(reach) {
                included.insert(index)
                cluster = cluster.union(rect)
                grew = true
            }
        }
        return cluster.insetBy(dx: -8, dy: -8)
    }

    /// A pin rectangle for a tap that didn't hit any ink.
    static func defaultRect(at point: CGPoint, within bounds: CGRect) -> CGRect {
        let size = CGSize(width: 160, height: 64)
        var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect.intersection(bounds)
    }
}

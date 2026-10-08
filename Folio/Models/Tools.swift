import PencilKit
import UIKit

enum ToolKind: String, CaseIterable, Identifiable {
    case read, pen, marker, textHighlight, eraser, lasso, pin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return "Read"
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .textHighlight: return "Highlight Text"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        case .pin: return "Pin Note"
        }
    }

    var symbol: String {
        switch self {
        case .read: return "hand.point.up.left"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .textHighlight: return "character.cursor.ibeam"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .pin: return "pin"
        }
    }

    /// Tools that are handled by PencilKit itself.
    var isInkTool: Bool {
        switch self {
        case .pen, .marker, .eraser, .lasso: return true
        case .read, .textHighlight, .pin: return false
        }
    }

    /// Tools that need single-finger drags/taps on the page, so page turning
    /// gestures have to be switched off while they are active.
    var capturesTouches: Bool { self == .textHighlight || self == .pin }
}

enum PenStyle: String, CaseIterable, Identifiable {
    case pen, fountain, monoline, pencil

    var id: String { rawValue }
    var name: String {
        switch self {
        case .pen: return "Ballpoint"
        case .fountain: return "Fountain"
        case .monoline: return "Monoline"
        case .pencil: return "Pencil"
        }
    }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: return .pen
        case .fountain: return .fountainPen
        case .monoline: return .monoline
        case .pencil: return .pencil
        }
    }
}

enum StrokeSize: String, CaseIterable, Identifiable {
    case fine, medium, bold

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// Dot size used for the size picker UI.
    var dot: CGFloat {
        switch self {
        case .fine: return 5
        case .medium: return 9
        case .bold: return 14
        }
    }

    /// Widths follow PencilKit's own scale for each ink (the units differ:
    /// pen 0.88–25.7, monoline 0.5–4, marker 7.5–60). "Medium" is the ink's
    /// default, and the three sizes are always visibly different.
    func penWidth(_ style: PenStyle) -> CGFloat {
        width(for: style.inkType)
    }

    var markerWidth: CGFloat {
        width(for: .marker)
    }

    private func width(for ink: PKInkingTool.InkType) -> CGFloat {
        let range = ink.validWidthRange
        func clamped(_ width: CGFloat) -> CGFloat { min(max(width, range.lowerBound), range.upperBound) }
        let fine = clamped(ink.defaultWidth * 0.6)
        let medium = clamped(max(ink.defaultWidth, fine * 1.5))
        let bold = clamped(max(ink.defaultWidth * 1.8, medium * 1.6))
        switch self {
        case .fine: return fine
        case .medium: return medium
        case .bold: return bold
        }
    }
}

enum EraserStyle: String, CaseIterable, Identifiable {
    case stroke, pixel

    var id: String { rawValue }
    var name: String { self == .stroke ? "Stroke Eraser" : "Pixel Eraser" }
}

/// The tool configuration shared by every page and whiteboard canvas.
struct ToolState: Equatable {
    var kind: ToolKind = .pen
    var penStyle: PenStyle = .pen
    var inkColor: InkColor = .black
    var penSize: StrokeSize = .medium
    var markColor: MarkColor = .yellow
    var markerSize: StrokeSize = .medium
    var eraser: EraserStyle = .stroke
    var pinColor: PinColor = .red

    var pencilKitTool: PKTool? {
        switch kind {
        case .pen:
            return PKInkingTool(penStyle.inkType, color: inkColor.uiColor, width: penSize.penWidth(penStyle))
        case .marker:
            return PKInkingTool(.marker, color: markColor.uiColor, width: markerSize.markerWidth)
        case .eraser:
            return eraser == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap)
        case .lasso:
            return PKLassoTool()
        case .read, .textHighlight, .pin:
            return nil
        }
    }
}

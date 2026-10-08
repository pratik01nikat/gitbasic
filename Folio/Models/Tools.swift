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

    /// Pen widths are relative to PencilKit's own default for each ink, so
    /// "Medium" always matches the system tool picker's default thickness.
    func penWidth(_ style: PenStyle) -> CGFloat {
        let factor: CGFloat
        switch self {
        case .fine: factor = 0.6
        case .medium: factor = 1
        case .bold: factor = 1.8
        }
        return Self.width(for: style.inkType, factor: factor)
    }

    var markerWidth: CGFloat {
        let factor: CGFloat
        switch self {
        case .fine: factor = 0.7
        case .medium: factor = 1
        case .bold: factor = 1.6
        }
        return Self.width(for: .marker, factor: factor)
    }

    private static func width(for ink: PKInkingTool.InkType, factor: CGFloat) -> CGFloat {
        let range = ink.validWidthRange
        return min(max(ink.defaultWidth * factor, range.lowerBound), range.upperBound)
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

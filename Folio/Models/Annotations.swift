import UIKit

// MARK: - Colors

/// Translucent colors used for text highlights and the freehand marker.
enum MarkColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, orange

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1)
        case .green: return UIColor(red: 0.52, green: 0.86, blue: 0.42, alpha: 1)
        case .blue: return UIColor(red: 0.42, green: 0.74, blue: 1.00, alpha: 1)
        case .pink: return UIColor(red: 1.00, green: 0.52, blue: 0.74, alpha: 1)
        case .orange: return UIColor(red: 1.00, green: 0.64, blue: 0.28, alpha: 1)
        }
    }

    var name: String { rawValue.capitalized }
}

/// Solid colors for pens.
enum InkColor: String, Codable, CaseIterable, Identifiable {
    case black, navy, blue, red, green, purple, orange

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .black: return UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        case .navy: return UIColor(red: 0.10, green: 0.18, blue: 0.42, alpha: 1)
        case .blue: return UIColor(red: 0.05, green: 0.42, blue: 0.90, alpha: 1)
        case .red: return UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1)
        case .green: return UIColor(red: 0.10, green: 0.56, blue: 0.30, alpha: 1)
        case .purple: return UIColor(red: 0.50, green: 0.24, blue: 0.80, alpha: 1)
        case .orange: return UIColor(red: 0.95, green: 0.48, blue: 0.08, alpha: 1)
        }
    }

    var name: String { rawValue.capitalized }
}

/// Colors for numbered pins.
enum PinColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, green, blue, purple

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .red: return UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1)
        case .orange: return UIColor(red: 0.96, green: 0.52, blue: 0.10, alpha: 1)
        case .green: return UIColor(red: 0.16, green: 0.62, blue: 0.34, alpha: 1)
        case .blue: return UIColor(red: 0.12, green: 0.46, blue: 0.94, alpha: 1)
        case .purple: return UIColor(red: 0.55, green: 0.28, blue: 0.86, alpha: 1)
        }
    }

    var name: String { rawValue.capitalized }
}

// MARK: - Annotation records

/// A highlight that snaps to the PDF's text.
/// `rects` are in page space: points, origin top-left, y pointing down.
struct Highlight: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var pageIndex: Int
    var rects: [CGRect]
    var text: String
    var color: MarkColor
    var createdAt: Date = Date()

    var bounds: CGRect { rects.reduce(CGRect.null) { $0.union($1) } }
}

/// Where a piece of handwriting lives: on a book page or on a whiteboard.
enum NoteSurface: Codable, Hashable {
    case page(Int)
    case board(UUID)
}

/// A numbered bookmark for a region of handwriting. Pins are listed in the
/// sidebar and tapping one jumps back to the exact spot.
/// `rect` is in the surface's drawing space (page space for pages).
struct Pin: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var number: Int
    var surface: NoteSurface
    var rect: CGRect
    var title: String
    var color: PinColor
    var createdAt: Date = Date()
}

enum BoardBackground: String, Codable, CaseIterable, Identifiable {
    case plain, lined, grid, dotted

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .plain: return "square"
        case .lined: return "line.3.horizontal"
        case .grid: return "grid"
        case .dotted: return "circle.grid.3x3"
        }
    }
}

/// A separate notebook page that belongs to a book.
struct Whiteboard: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var background: BoardBackground = .lined
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// Everything except ink (which is stored per page / per board as PKDrawing data).
struct BookAnnotations: Codable {
    var highlights: [Highlight] = []
    var pins: [Pin] = []
    var bookmarks: [Int] = []
    var boards: [Whiteboard] = []

    init() {}

    // Tolerant decoding so files written by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        bookmarks = try c.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        boards = try c.decodeIfPresent([Whiteboard].self, forKey: .boards) ?? []
    }

    var nextPinNumber: Int { (pins.map(\.number).max() ?? 0) + 1 }

    func pins(on surface: NoteSurface) -> [Pin] {
        pins.filter { $0.surface == surface }
    }

    func highlights(onPage index: Int) -> [Highlight] {
        highlights.filter { $0.pageIndex == index }
    }
}

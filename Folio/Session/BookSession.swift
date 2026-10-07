import Combine
import PDFKit
import PencilKit
import SwiftUI

enum WorkspaceLayout: String {
    /// Only the book.
    case book
    /// Only the active whiteboard.
    case board
    /// Book on the left, whiteboard on the right.
    case split
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case pins, highlights, bookmarks, contents, boards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pins: return "Pinned Notes"
        case .highlights: return "Highlights"
        case .bookmarks: return "Bookmarks"
        case .contents: return "Contents"
        case .boards: return "Whiteboards"
        }
    }

    var symbol: String {
        switch self {
        case .pins: return "pin.fill"
        case .highlights: return "highlighter"
        case .bookmarks: return "bookmark.fill"
        case .contents: return "list.bullet.indent"
        case .boards: return "rectangle.and.pencil.and.ellipsis"
        }
    }
}

/// Request for a surface to scroll/turn to a place and flash it.
struct FocusRequest: Equatable {
    let id = UUID()
    let surface: NoteSurface
    let rect: CGRect?
    let animated: Bool
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [OutlineItem]?
}

/// State for one open book: the document, every annotation, the shared tool,
/// and navigation between pages, whiteboards and the sidebar.
@MainActor
final class BookSession: ObservableObject, Identifiable {
    nonisolated var id: UUID { bookID }
    let bookID: UUID
    let document: PDFDocument
    let renderer: PageRenderer
    let files: BookFiles
    let pageCount: Int
    private let library: LibraryStore

    @Published private(set) var title: String
    @Published var annotations: BookAnnotations {
        didSet { scheduleAnnotationsSave() }
    }
    @Published private(set) var currentPage: Int
    @Published private(set) var visiblePages: [Int] = []
    @Published private(set) var pagesWithInk: Set<Int>
    /// Bumped whenever ink is saved, so thumbnails know to refresh.
    @Published private(set) var inkRevision = 0

    @Published var tool = ToolState()
    @Published var fingerDrawing: Bool {
        didSet { UserDefaults.standard.set(fingerDrawing, forKey: Keys.fingerDrawing) }
    }
    @Published var twoPageSpread: Bool {
        didSet { UserDefaults.standard.set(twoPageSpread, forKey: Keys.twoPageSpread) }
    }
    @Published var pageTurnHaptics: Bool {
        didSet { UserDefaults.standard.set(pageTurnHaptics, forKey: Keys.haptics) }
    }

    @Published var layout: WorkspaceLayout = .book
    @Published var activeBoardID: UUID?
    @Published var sidebarTab: SidebarTab = .pins
    @Published var showsToolPalette = true
    @Published var toast: Toast?

    @Published var pageFocus: FocusRequest?
    @Published var boardFocus: FocusRequest?

    /// The canvas that most recently received ink; undo/redo go to it.
    weak var activeCanvas: PKCanvasView?

    private var pageInk: [Int: PKDrawing] = [:]
    private var boardInk: [UUID: PKDrawing] = [:]
    private var dirtyPages = Set<Int>()
    private var dirtyBoards = Set<UUID>()
    private var inkSaveTask: Task<Void, Never>?
    private var annotationsSaveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var previousToolKind: ToolKind = .pen
    private lazy var outlineCache: [OutlineItem] = Self.buildOutline(document.outlineRoot, document: document)

    private enum Keys {
        static let fingerDrawing = "folio.fingerDrawing"
        static let twoPageSpread = "folio.twoPageSpread"
        static let haptics = "folio.pageTurnHaptics"
    }

    init?(book: Book, library: LibraryStore) {
        let files = library.files(for: book)
        guard let document = PDFDocument(url: files.pdf), document.pageCount > 0 else { return nil }
        self.bookID = book.id
        self.library = library
        self.files = files
        self.document = document
        self.pageCount = document.pageCount
        self.renderer = PageRenderer(url: files.pdf, pdf: document)
        self.title = book.title
        self.annotations = files.loadAnnotations()
        self.pagesWithInk = files.pagesWithInk()
        self.currentPage = min(max(book.lastPageIndex, 0), document.pageCount - 1)
        let defaults = UserDefaults.standard
        // Without a saved choice, follow iPadOS: once an Apple Pencil has been
        // used, "Only Draw with Apple Pencil" is on and fingers turn pages.
        let fingerDrawing = defaults.object(forKey: Keys.fingerDrawing) as? Bool ?? !UIPencilInteraction.prefersPencilOnlyDrawing
        self.fingerDrawing = fingerDrawing
        self.twoPageSpread = defaults.object(forKey: Keys.twoPageSpread) as? Bool ?? true
        self.pageTurnHaptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        try? files.createFolders()
        self.activeBoardID = annotations.boards.first?.id
        // Start ready to write with Apple Pencil; without one, start in Read
        // mode so a finger turns pages instead of drawing.
        self.tool.kind = fingerDrawing ? .read : .pen
    }

    // MARK: - Tools

    func select(_ kind: ToolKind) {
        if tool.kind != kind { previousToolKind = tool.kind }
        tool.kind = kind
    }

    /// Apple Pencil double-tap / squeeze: jump to the eraser and back.
    func toggleEraser() {
        if tool.kind == .eraser {
            select(previousToolKind == .eraser ? .pen : previousToolKind)
        } else {
            select(.eraser)
        }
    }

    /// Apple Pencil double-tap set to "Switch between current tool and last used tool".
    func switchToPreviousTool() {
        select(previousToolKind)
    }

    func undo() { activeCanvas?.undoManager?.undo() }
    func redo() { activeCanvas?.undoManager?.redo() }

    // MARK: - Ink

    func drawing(forPage index: Int) -> PKDrawing {
        if let drawing = pageInk[index] { return drawing }
        let drawing = files.loadDrawing(at: files.ink(page: index))
        pageInk[index] = drawing
        return drawing
    }

    func setDrawing(_ drawing: PKDrawing, forPage index: Int) {
        pageInk[index] = drawing
        dirtyPages.insert(index)
        scheduleInkSave()
    }

    func drawing(forBoard id: UUID) -> PKDrawing {
        if let drawing = boardInk[id] { return drawing }
        let drawing = files.loadDrawing(at: files.board(id))
        boardInk[id] = drawing
        return drawing
    }

    func setDrawing(_ drawing: PKDrawing, forBoard id: UUID) {
        boardInk[id] = drawing
        dirtyBoards.insert(id)
        scheduleInkSave()
    }

    func drawing(for surface: NoteSurface) -> PKDrawing {
        switch surface {
        case .page(let index): return drawing(forPage: index)
        case .board(let id): return drawing(forBoard: id)
        }
    }

    private func scheduleInkSave() {
        inkSaveTask?.cancel()
        inkSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingInk()
        }
    }

    /// Writes ink that changed since the last save.
    func flushPendingInk() {
        guard !dirtyPages.isEmpty || !dirtyBoards.isEmpty else { return }
        for index in dirtyPages {
            let drawing = pageInk[index] ?? PKDrawing()
            if drawing.strokes.isEmpty {
                DiskWriter.remove(files.ink(page: index))
                pagesWithInk.remove(index)
            } else {
                DiskWriter.write(drawing.dataRepresentation(), to: files.ink(page: index))
                pagesWithInk.insert(index)
            }
        }
        if !dirtyBoards.isEmpty {
            for id in dirtyBoards {
                DiskWriter.write((boardInk[id] ?? PKDrawing()).dataRepresentation(), to: files.board(id))
            }
            let now = Date()
            for index in annotations.boards.indices where dirtyBoards.contains(annotations.boards[index].id) {
                annotations.boards[index].updatedAt = now
            }
        }
        dirtyPages.removeAll()
        dirtyBoards.removeAll()
        inkRevision += 1
    }

    // MARK: - Saving

    private func scheduleAnnotationsSave() {
        annotationsSaveTask?.cancel()
        annotationsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.writeAnnotations()
        }
    }

    private func writeAnnotations() {
        guard let data = try? JSONCoding.encoder.encode(annotations) else { return }
        DiskWriter.write(data, to: files.annotations)
    }

    /// Writes everything to disk now (app moving to background, book closing).
    func saveNow() {
        inkSaveTask?.cancel()
        annotationsSaveTask?.cancel()
        flushPendingInk()
        writeAnnotations()
        library.saveProgress(bookID: bookID, pageIndex: currentPage)
        DiskWriter.flush()
    }

    // MARK: - Navigation

    /// Called by the reader whenever the visible pages change.
    func readerDidShow(pages: [Int]) {
        guard !pages.isEmpty, pages != visiblePages else { return }
        visiblePages = pages
        currentPage = pages[0]
        library.saveProgress(bookID: bookID, pageIndex: currentPage)
    }

    func goToPage(_ index: Int, flash rect: CGRect? = nil, animated: Bool = true) {
        let page = min(max(index, 0), pageCount - 1)
        if layout == .board { layout = .book }
        pageFocus = FocusRequest(surface: .page(page), rect: rect, animated: animated)
    }

    func turnPage(forward: Bool) {
        let target = forward ? (visiblePages.last ?? currentPage) + 1 : (visiblePages.first ?? currentPage) - 1
        guard (0..<pageCount).contains(target) else { return }
        goToPage(target)
    }

    func open(_ pin: Pin) {
        switch pin.surface {
        case .page(let index): goToPage(index, flash: pin.rect)
        case .board(let id): openBoard(id, flash: pin.rect)
        }
    }

    func open(_ highlight: Highlight) {
        goToPage(highlight.pageIndex, flash: highlight.bounds)
    }

    func openBoard(_ id: UUID, flash rect: CGRect? = nil) {
        guard annotations.boards.contains(where: { $0.id == id }) else { return }
        activeBoardID = id
        if layout == .book { layout = .board }
        boardFocus = FocusRequest(surface: .board(id), rect: rect, animated: true)
    }

    func toggleSplit() {
        if layout == .split {
            layout = .book
        } else {
            if activeBoard == nil { createBoard() }
            layout = .split
        }
    }

    // MARK: - Pins

    var sortedPins: [Pin] { annotations.pins.sorted { $0.number < $1.number } }

    @discardableResult
    func addPin(on surface: NoteSurface, rect: CGRect) -> Pin {
        let number = annotations.nextPinNumber
        let pin = Pin(number: number, surface: surface, rect: rect.integral, title: "Note \(number)", color: tool.pinColor)
        annotations.pins.append(pin)
        showToast("Pinned note \(number)", symbol: "pin.fill")
        return pin
    }

    func renamePin(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.pins.firstIndex(where: { $0.id == id }) else { return }
        annotations.pins[index].title = trimmed.isEmpty ? "Note \(annotations.pins[index].number)" : trimmed
    }

    func setPinColor(_ id: UUID, _ color: PinColor) {
        guard let index = annotations.pins.firstIndex(where: { $0.id == id }) else { return }
        annotations.pins[index].color = color
    }

    func deletePin(_ id: UUID) {
        var pins = sortedPins
        pins.removeAll { $0.id == id }
        annotations.pins = Self.renumbered(pins)
    }

    /// Reorders pins as in the sidebar list (which is sorted by number) and renumbers 1...n.
    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        var pins = sortedPins
        pins.move(fromOffsets: source, toOffset: destination)
        annotations.pins = Self.renumbered(pins)
    }

    /// Renumbers pins in reading order: book pages first, then whiteboards,
    /// top-to-bottom and left-to-right within each.
    func renumberPinsByPageOrder() {
        let boardOrder = Dictionary(uniqueKeysWithValues: annotations.boards.enumerated().map { ($1.id, $0) })
        func key(_ pin: Pin) -> (Int, Int, CGFloat, CGFloat) {
            switch pin.surface {
            case .page(let index): return (0, index, pin.rect.minY, pin.rect.minX)
            case .board(let id): return (1, boardOrder[id] ?? Int.max, pin.rect.minY, pin.rect.minX)
            }
        }
        let pins = annotations.pins.sorted { key($0) < key($1) }
        annotations.pins = Self.renumbered(pins)
        showToast("Pins renumbered in page order", symbol: "list.number")
    }

    private static func renumbered(_ pins: [Pin]) -> [Pin] {
        pins.enumerated().map { offset, pin in
            var pin = pin
            let oldDefault = "Note \(pin.number)"
            pin.number = offset + 1
            if pin.title == oldDefault { pin.title = "Note \(pin.number)" }
            return pin
        }
    }

    func surfaceName(_ surface: NoteSurface) -> String {
        switch surface {
        case .page(let index): return pageLabel(index)
        case .board(let id): return annotations.boards.first { $0.id == id }?.title ?? "Whiteboard"
        }
    }

    // MARK: - Highlights

    func addHighlight(page: Int, rects: [CGRect], text: String) {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        annotations.highlights.append(Highlight(pageIndex: page, rects: rects, text: cleaned, color: tool.markColor))
    }

    func setHighlightColor(_ id: UUID, _ color: MarkColor) {
        guard let index = annotations.highlights.firstIndex(where: { $0.id == id }) else { return }
        annotations.highlights[index].color = color
    }

    func deleteHighlight(_ id: UUID) {
        annotations.highlights.removeAll { $0.id == id }
    }

    var sortedHighlights: [Highlight] {
        annotations.highlights.sorted {
            ($0.pageIndex, $0.bounds.minY, $0.bounds.minX) < ($1.pageIndex, $1.bounds.minY, $1.bounds.minX)
        }
    }

    // MARK: - Bookmarks

    func isBookmarked(_ page: Int) -> Bool { annotations.bookmarks.contains(page) }

    var isCurrentPageBookmarked: Bool {
        (visiblePages.isEmpty ? [currentPage] : visiblePages).contains(where: isBookmarked)
    }

    func toggleBookmarkForCurrentPage() {
        let pages = visiblePages.isEmpty ? [currentPage] : visiblePages
        if let marked = pages.first(where: isBookmarked) {
            annotations.bookmarks.removeAll { $0 == marked }
        } else {
            annotations.bookmarks = (annotations.bookmarks + [currentPage]).sorted()
            showToast("Bookmarked \(pageLabel(currentPage).lowercased())", symbol: "bookmark.fill")
        }
    }

    func removeBookmark(_ page: Int) {
        annotations.bookmarks.removeAll { $0 == page }
    }

    // MARK: - Whiteboards

    var activeBoard: Whiteboard? {
        guard let id = activeBoardID else { return nil }
        return annotations.boards.first { $0.id == id }
    }

    @discardableResult
    func createBoard() -> Whiteboard {
        let board = Whiteboard(title: "Whiteboard \(annotations.boards.count + 1)")
        annotations.boards.append(board)
        activeBoardID = board.id
        return board
    }

    func renameBoard(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = annotations.boards.firstIndex(where: { $0.id == id }) else { return }
        annotations.boards[index].title = trimmed
    }

    func setBackground(_ background: BoardBackground, forBoard id: UUID) {
        guard let index = annotations.boards.firstIndex(where: { $0.id == id }) else { return }
        annotations.boards[index].background = background
    }

    func deleteBoard(_ id: UUID) {
        var updated = annotations
        updated.boards.removeAll { $0.id == id }
        updated.pins = Self.renumbered(updated.pins.sorted { $0.number < $1.number }.filter { $0.surface != .board(id) })
        annotations = updated
        boardInk[id] = nil
        dirtyBoards.remove(id)
        DiskWriter.remove(files.board(id))
        if activeBoardID == id {
            activeBoardID = annotations.boards.first?.id
            if activeBoardID == nil { layout = .book }
        }
    }

    // MARK: - Contents

    var outline: [OutlineItem] { outlineCache }

    private static func buildOutline(_ node: PDFOutline?, document: PDFDocument) -> [OutlineItem] {
        guard let node else { return [] }
        return (0..<node.numberOfChildren).compactMap { index in
            guard let child = node.child(at: index) else { return nil }
            let page = child.destination?.page.map { document.index(for: $0) }
            let children = buildOutline(child, document: document)
            return OutlineItem(title: child.label ?? "Untitled", pageIndex: page, children: children.isEmpty ? nil : children)
        }
    }

    // MARK: - Labels & feedback

    /// "Page 12", using the PDF's own page label when it has one (e.g. "xii").
    func pageLabel(_ index: Int) -> String {
        if let label = document.page(at: index)?.label, !label.isEmpty, label != "\(index + 1)" {
            return "Page \(label)"
        }
        return "Page \(index + 1)"
    }

    func showToast(_ message: String, symbol: String) {
        toast = Toast(message: message, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

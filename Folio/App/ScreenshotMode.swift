#if DEBUG
import PDFKit
import PencilKit
import SwiftUI

/// Debug builds only. Launching with `-FolioScreenshot <scene>` opens the
/// welcome book straight into a scene, with sample handwriting, pins, a
/// highlight and a whiteboard, so CI can capture real simulator screenshots.
/// `-FolioOrientation landscape` asks for landscape.
enum ScreenshotScene: String {
    case library, reader, pins, split, board

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "FolioScreenshot").flatMap(ScreenshotScene.init(rawValue:))
    }

    static var wantsLandscape: Bool {
        UserDefaults.standard.string(forKey: "FolioOrientation") == "landscape"
    }

    var sidebarVisibility: NavigationSplitViewVisibility {
        self == .pins ? .all : .detailOnly
    }
}

@MainActor
enum ScreenshotSeeder {
    static func prepare(library: LibraryStore) -> BookSession? {
        if ScreenshotScene.wantsLandscape,
           let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                print("Folio screenshots: landscape request failed: \(error)")
            }
        }
        guard let scene = ScreenshotScene.current, scene != .library, let book = library.books.first else { return nil }
        library.saveProgress(bookID: book.id, pageIndex: min(4, book.pageCount - 1))
        guard let current = library.book(withID: book.id),
              let session = BookSession(book: current, library: library) else { return nil }
        seed(session)
        session.sidebarTab = .pins
        session.select(scene == .reader || scene == .split ? .pin : .pen)
        switch scene {
        case .split: session.layout = .split
        case .board: session.layout = .board
        case .library, .reader, .pins: session.layout = .book
        }
        session.toast = nil
        return session
    }

    /// Adds the sample annotations once; later launches reuse them.
    private static func seed(_ session: BookSession) {
        guard session.annotations.pins.isEmpty else { return }
        let last = session.pageCount - 1

        // A margin note on page 5, pinned as note 1.
        let notePage = min(4, last)
        let note = handwriting(origin: CGPoint(x: 74, y: 600), lines: 3, width: 300, color: InkColor.navy.uiColor, seed: 3)
        addInk(note, toPage: notePage, in: session)
        let first = session.addPin(on: .page(notePage), rect: bounds(of: note))
        session.setPinColor(first.id, .red)

        // A short note on page 2, pinned and renamed.
        let secondPage = min(1, last)
        let note2 = handwriting(origin: CGPoint(x: 320, y: 610), lines: 2, width: 220, color: InkColor.red.uiColor, seed: 11)
        addInk(note2, toPage: secondPage, in: session)
        let second = session.addPin(on: .page(secondPage), rect: bounds(of: note2))
        session.setPinColor(second.id, .blue)
        session.renamePin(second.id, to: "Gestures to remember")

        // A text highlight on page 4.
        for phrase in ["The highlight snaps to the words", "snaps to the words"] {
            guard let selection = session.document.findString(phrase, withOptions: .caseInsensitive).first,
                  let page = selection.pages.first else { continue }
            let index = session.document.index(for: page)
            let rects = page.lineRects(of: selection, geometry: session.renderer.geometry(index))
            guard !rects.isEmpty else { continue }
            session.addHighlight(page: index, rects: rects, text: selection.string ?? phrase)
            break
        }

        session.annotations.bookmarks = Array(Set([secondPage, notePage])).sorted()

        // A lined whiteboard with a pinned summary.
        let board = session.createBoard()
        session.setBackground(.lined, forBoard: board.id)
        let summary = handwriting(origin: CGPoint(x: 140, y: 170), lines: 4, width: 700, color: InkColor.black.uiColor,
                                  seed: 5, xHeight: 13, lineHeight: 64, penWidth: 3)
        session.setDrawing(PKDrawing(strokes: summary), forBoard: board.id)
        let third = session.addPin(on: .board(board.id), rect: bounds(of: summary))
        session.setPinColor(third.id, .orange)

        session.saveNow()
    }

    private static func addInk(_ strokes: [PKStroke], toPage page: Int, in session: BookSession) {
        var drawing = session.drawing(forPage: page)
        drawing.strokes.append(contentsOf: strokes)
        session.setDrawing(drawing, forPage: page)
    }

    private static func bounds(of strokes: [PKStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -8, dy: -8)
    }

    /// Cursive-looking scribbles: words made of loops, some letters tall.
    private static func handwriting(origin: CGPoint, lines: Int, width: CGFloat, color: UIColor, seed: UInt64,
                                    xHeight: CGFloat = 7, lineHeight: CGFloat = 30, penWidth: CGFloat = 1.8) -> [PKStroke] {
        var random = SeededGenerator(seed: seed)
        let ink = PKInk(.pen, color: color)
        var strokes: [PKStroke] = []
        for line in 0..<lines {
            let baseline = origin.y + CGFloat(line) * lineHeight
            let lineEnd = origin.x + (line == lines - 1 ? width * 0.6 : width)
            var x = origin.x
            while x < lineEnd - xHeight * 3 {
                var points: [PKStrokePoint] = []
                var time: TimeInterval = 0
                for _ in 0..<Int.random(in: 3...7, using: &random) {
                    let tall = Double.random(in: 0...1, using: &random) < 0.25
                    let height = tall ? xHeight * 2.1 : xHeight
                    let letterWidth = CGFloat.random(in: (xHeight * 0.9)...(xHeight * 1.4), using: &random)
                    for step in 0...8 {
                        let progress = CGFloat(step) / 8
                        let location = CGPoint(
                            x: x + letterWidth * progress - sin(progress * .pi * 2) * letterWidth * 0.25,
                            y: baseline - sin(progress * .pi) * height
                        )
                        points.append(PKStrokePoint(location: location, timeOffset: time,
                                                    size: CGSize(width: penWidth, height: penWidth),
                                                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                        time += 0.008
                    }
                    x += letterWidth
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
                x += CGFloat.random(in: (xHeight * 1.2)...(xHeight * 2), using: &random)
            }
        }
        return strokes
    }
}

/// Deterministic random numbers so every run draws the same sample ink.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = (seed &* 0x9E37_79B9_7F4A_7C15) | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
#endif

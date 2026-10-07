import UIKit

/// Generates a small guide PDF on first launch so there is something to read,
/// flip, highlight and write on before the user imports their own books.
enum SampleBook {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 64

    private struct Chapter {
        let title: String
        let paragraphs: [String]
    }

    private static let chapters: [Chapter] = [
        Chapter(title: "Turning pages", paragraphs: [
            "Folio turns pages like a paper book. Drag a corner or the edge of a page with your finger and the page curls over. A quick tap near the left or right edge also turns the page.",
            "Rotate your iPad to landscape for a two-page spread, with the cover on its own just like a printed book. The slider at the bottom jumps anywhere in the book, and the ribbon button in the top bar bookmarks the current page.",
            "Pinch with two fingers to zoom into a page. While zoomed, one finger moves around the page; zoom back out to turn pages again.",
        ]),
        Chapter(title: "Writing with Apple Pencil", paragraphs: [
            "With a writing tool selected, Apple Pencil writes and your finger turns pages, so you can read and annotate without switching modes. Pick the pen, marker, eraser or lasso from the tool bar at the top, and tap the color button (or the selected tool again) to change color, pen style and thickness. The hand tool is for reading only.",
            "No Apple Pencil? Tap the hand-drawing button at the end of the tool bar so your finger can write. Page turning then moves to the slider and the arrow buttons at the bottom.",
            "Double-tap or squeeze Apple Pencil (on supported models) to switch to the eraser and back, following the setting you chose in iPadOS Settings.",
        ]),
        Chapter(title: "Highlighting", paragraphs: [
            "Choose Highlight Text and drag across a sentence. The highlight snaps to the words, exactly like a highlighter pen that never goes outside the lines. Every highlight shows up in the sidebar with the quoted text, so you can find it again later.",
            "Tap an existing highlight while Highlight Text is selected to change its color, copy the text or remove it.",
            "For scanned books without selectable text, use the Marker tool instead and highlight freehand.",
        ]),
        Chapter(title: "Pinning handwritten notes", paragraphs: [
            "Write a note in the margin of this page. Then pick the Pin tool and tap on your handwriting. Folio finds the whole note and pins it with a number. You can also drag a rectangle to pin exactly the area you want.",
            "Pins are numbered 1, 2, 3 in the order you create them and are listed in the sidebar with a picture of your handwriting. Tap a pin in the sidebar and Folio turns to that page and flashes the note.",
            "Touch and hold a pin in the sidebar to rename, recolor or delete it, or tap its number badge on the page while the Pin tool is selected. Use Edit to drag pins into a new order, or renumber them in page order from the sidebar menu.",
        ]),
        Chapter(title: "Whiteboards", paragraphs: [
            "Every book can have any number of whiteboards: blank, lined, grid or dotted pages for longer notes, summaries and diagrams.",
            "Open a whiteboard on its own, or use split view to keep the book on the left and the whiteboard on the right while you read. Handwriting on whiteboards can be pinned too, and those pins appear in the same numbered list as the pins in the book.",
            "When you are done, share an annotated copy of the book with all your ink, highlights and whiteboards included.",
        ]),
    ]

    static func writeWelcomePDF(to url: URL) throws {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Welcome to Folio",
            kCGPDFContextAuthor as String: "Folio",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            drawCover()

            for (index, chapter) in chapters.enumerated() {
                context.beginPage()
                drawChapter(chapter, number: index + 1)
                drawFooter(page: index + 2)
            }

            context.beginPage()
            drawPracticePage()
            drawFooter(page: chapters.count + 2)
        }
    }

    private static func drawCover() {
        UIColor(red: 0.14, green: 0.20, blue: 0.30, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: pageSize))

        let title = NSAttributedString(string: "Folio", attributes: [
            .font: UIFont(name: "Georgia-Bold", size: 72) ?? .boldSystemFont(ofSize: 72),
            .foregroundColor: UIColor(red: 0.98, green: 0.93, blue: 0.80, alpha: 1),
        ])
        let subtitle = NSAttributedString(string: "A guide to reading, writing\nand pinning your notes", attributes: [
            .font: UIFont(name: "Georgia-Italic", size: 22) ?? .italicSystemFont(ofSize: 22),
            .foregroundColor: UIColor(white: 0.9, alpha: 1),
            .paragraphStyle: centered(lineSpacing: 6),
        ])
        let titleSize = title.size()
        title.draw(at: CGPoint(x: (pageSize.width - titleSize.width) / 2, y: 250))
        subtitle.draw(in: CGRect(x: margin, y: 360, width: pageSize.width - margin * 2, height: 80))

        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: pageSize.width / 2 - 60, y: 340))
        rule.addLine(to: CGPoint(x: pageSize.width / 2 + 60, y: 340))
        UIColor(red: 0.98, green: 0.93, blue: 0.80, alpha: 0.7).setStroke()
        rule.lineWidth = 1.5
        rule.stroke()
    }

    private static func drawChapter(_ chapter: Chapter, number: Int) {
        var y: CGFloat = margin + 10
        let width = pageSize.width - margin * 2

        let label = NSAttributedString(string: "CHAPTER \(number)", attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor(red: 0.75, green: 0.35, blue: 0.18, alpha: 1),
            .kern: 2,
        ])
        label.draw(at: CGPoint(x: margin, y: y))
        y += 26

        let title = NSAttributedString(string: chapter.title, attributes: [
            .font: UIFont(name: "Georgia-Bold", size: 30) ?? .boldSystemFont(ofSize: 30),
            .foregroundColor: UIColor(white: 0.1, alpha: 1),
        ])
        title.draw(at: CGPoint(x: margin, y: y))
        y += 64

        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15),
            .foregroundColor: UIColor(white: 0.15, alpha: 1),
            .paragraphStyle: justified(lineSpacing: 6),
        ]
        for paragraph in chapter.paragraphs {
            let text = NSAttributedString(string: paragraph, attributes: body)
            let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            text.draw(with: CGRect(x: margin, y: y, width: width, height: height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += height + 18
        }
    }

    private static func drawPracticePage() {
        let title = NSAttributedString(string: "Practice page", attributes: [
            .font: UIFont(name: "Georgia-Bold", size: 26) ?? .boldSystemFont(ofSize: 26),
            .foregroundColor: UIColor(white: 0.1, alpha: 1),
        ])
        title.draw(at: CGPoint(x: margin, y: margin))
        let hint = NSAttributedString(string: "Write something below, then pin it with the Pin tool.", attributes: [
            .font: UIFont(name: "Georgia-Italic", size: 14) ?? .italicSystemFont(ofSize: 14),
            .foregroundColor: UIColor(white: 0.4, alpha: 1),
        ])
        hint.draw(at: CGPoint(x: margin, y: margin + 40))

        UIColor(red: 0.62, green: 0.74, blue: 0.86, alpha: 0.8).setStroke()
        var y = margin + 100
        while y < pageSize.height - margin {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: margin, y: y))
            line.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
            line.lineWidth = 0.75
            line.stroke()
            y += 32
        }
    }

    private static func drawFooter(page: Int) {
        let text = NSAttributedString(string: "\(page)", attributes: [
            .font: UIFont(name: "Georgia", size: 11) ?? .systemFont(ofSize: 11),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - margin / 2 - size.height))
    }

    private static func centered(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = lineSpacing
        return style
    }

    private static func justified(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .justified
        style.lineSpacing = lineSpacing
        style.hyphenationFactor = 0.6
        return style
    }
}

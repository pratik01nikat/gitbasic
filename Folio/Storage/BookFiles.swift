import Foundation
import PencilKit

/// File layout for one book:
///
///     Library/<book-id>/
///         book.json            metadata (`Book`)
///         book.pdf             the imported PDF
///         annotations.json     highlights, pins, bookmarks, boards (`BookAnnotations`)
///         ink/page-<n>.drawing PencilKit data for page n (0-based)
///         boards/<id>.drawing  PencilKit data for a whiteboard
struct BookFiles {
    let folder: URL

    var metadata: URL { folder.appendingPathComponent("book.json") }
    var pdf: URL { folder.appendingPathComponent("book.pdf") }
    var annotations: URL { folder.appendingPathComponent("annotations.json") }
    var inkFolder: URL { folder.appendingPathComponent("ink", isDirectory: true) }
    var boardsFolder: URL { folder.appendingPathComponent("boards", isDirectory: true) }

    func ink(page: Int) -> URL { inkFolder.appendingPathComponent("page-\(page).drawing") }
    func board(_ id: UUID) -> URL { boardsFolder.appendingPathComponent("\(id.uuidString).drawing") }

    func createFolders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inkFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: boardsFolder, withIntermediateDirectories: true)
    }

    // MARK: Reading

    func loadAnnotations() -> BookAnnotations {
        guard let data = try? Data(contentsOf: annotations) else { return BookAnnotations() }
        do {
            return try JSONCoding.decoder.decode(BookAnnotations.self, from: data)
        } catch {
            // Keep the unreadable file around instead of overwriting it with an empty one.
            let backup = folder.appendingPathComponent("annotations-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: annotations, to: backup)
            print("Folio: could not decode annotations: \(error)")
            return BookAnnotations()
        }
    }

    func loadDrawing(at url: URL) -> PKDrawing {
        guard let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    /// Pages that have ink saved on disk.
    func pagesWithInk() -> Set<Int> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inkFolder.path)) ?? []
        var pages = Set<Int>()
        for name in names where name.hasPrefix("page-") && name.hasSuffix(".drawing") {
            let number = name.dropFirst("page-".count).dropLast(".drawing".count)
            if let page = Int(number) { pages.insert(page) }
        }
        return pages
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Serial background queue for disk writes so saving never blocks drawing.
enum DiskWriter {
    private static let queue = DispatchQueue(label: "folio.disk-writer", qos: .utility)

    static func write(_ data: Data, to url: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Folio: failed to write \(url.lastPathComponent): \(error)")
            }
        }
    }

    static func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Blocks until every queued write has finished (used when the app goes to background).
    static func flush() {
        queue.sync {}
    }
}

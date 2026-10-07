import PDFKit
import SwiftUI

enum LibraryError: LocalizedError {
    case unreadablePDF, lockedPDF, emptyPDF

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "This file couldn't be opened as a PDF."
        case .lockedPDF: return "This PDF is password protected. Remove the password and import it again."
        case .emptyPDF: return "This PDF has no pages."
        }
    }
}

/// Owns the list of imported books and their folders on disk.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    let root: URL
    private let coverCache = NSCache<NSString, UIImage>()
    private static let welcomeKey = "folio.didCreateWelcomeBook"

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        if books.isEmpty && !UserDefaults.standard.bool(forKey: Self.welcomeKey) {
            createWelcomeBook()
        }
    }

    func files(for book: Book) -> BookFiles {
        BookFiles(folder: root.appendingPathComponent(book.id.uuidString, isDirectory: true))
    }

    func book(withID id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let loaded: [Book] = folders.compactMap { folder in
            let files = BookFiles(folder: folder)
            guard let data = try? Data(contentsOf: files.metadata) else { return nil }
            return try? JSONCoding.decoder.decode(Book.self, from: data)
        }
        books = Self.sorted(loaded)
    }

    private static func sorted(_ list: [Book]) -> [Book] {
        list.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    // MARK: Import

    /// Copies a PDF into the library. Works with security-scoped URLs from the
    /// file importer and with files handed to the app via "Open in…".
    @discardableResult
    func importPDF(from url: URL) throws -> Book {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let files = BookFiles(folder: root.appendingPathComponent(id.uuidString, isDirectory: true))
        do {
            try files.createFolders()

            // Coordinated read so files stored in iCloud Drive get downloaded first.
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: files.pdf) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }

            guard let document = PDFDocument(url: files.pdf) else { throw LibraryError.unreadablePDF }
            if document.isLocked { throw LibraryError.lockedPDF }
            guard document.pageCount > 0 else { throw LibraryError.emptyPDF }

            let fileName = url.deletingPathExtension().lastPathComponent
            let book = Book(id: id, title: Self.title(for: document, fallback: fileName), pageCount: document.pageCount)
            try write(book)
            books = Self.sorted(books + [book])
            return book
        } catch {
            try? FileManager.default.removeItem(at: files.folder)
            throw error
        }
    }

    private static func title(for document: PDFDocument, fallback: String) -> String {
        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let looksGenerated = metadataTitle.count < 3
            || metadataTitle.lowercased().hasPrefix("microsoft")
            || [".doc", ".docx", ".pdf", ".indd", ".tex"].contains { metadataTitle.lowercased().hasSuffix($0) }
        return looksGenerated ? fallback : metadataTitle
    }

    private func createWelcomeBook() {
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Welcome to Folio.pdf")
        do {
            try SampleBook.writeWelcomePDF(to: url)
            try importPDF(from: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            print("Folio: could not create the welcome book: \(error)")
        }
    }

    // MARK: Editing

    func rename(_ book: Book, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(book.id) { $0.title = trimmed }
    }

    func delete(_ book: Book) {
        books.removeAll { $0.id == book.id }
        coverCache.removeObject(forKey: book.id.uuidString as NSString)
        try? FileManager.default.removeItem(at: files(for: book).folder)
    }

    func markOpened(_ book: Book) {
        update(book.id, resort: true) { $0.lastOpenedAt = Date() }
    }

    func saveProgress(bookID: UUID, pageIndex: Int) {
        guard let book = self.book(withID: bookID), book.lastPageIndex != pageIndex else { return }
        update(bookID) { $0.lastPageIndex = pageIndex }
    }

    private func update(_ id: UUID, resort: Bool = false, _ change: (inout Book) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        var book = books[index]
        change(&book)
        books[index] = book
        if resort { books = Self.sorted(books) }
        if let data = try? JSONCoding.encoder.encode(book) {
            DiskWriter.write(data, to: files(for: book).metadata)
        }
    }

    private func write(_ book: Book) throws {
        let data = try JSONCoding.encoder.encode(book)
        try data.write(to: files(for: book).metadata, options: .atomic)
    }

    // MARK: Covers

    func cover(for book: Book, width: CGFloat) async -> UIImage? {
        let key = "\(book.id.uuidString)-\(Int(width))" as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        let url = files(for: book).pdf
        let scale = UITraitCollection.current.displayScale
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let aspect = rotated ? bounds.width / bounds.height : bounds.height / bounds.width
            let size = CGSize(width: width * scale, height: width * aspect * scale)
            return page.thumbnail(of: size, for: .cropBox)
        }.value
        if let image { coverCache.setObject(image, forKey: key) }
        return image
    }
}

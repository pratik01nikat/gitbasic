import Foundation

/// A PDF that lives in the app's library. Its files (the PDF, ink, boards and
/// annotations) are stored together in one folder named after `id`.
struct Book: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var lastPageIndex: Int

    init(id: UUID = UUID(), title: String, pageCount: Int, addedAt: Date = Date(), lastOpenedAt: Date? = nil, lastPageIndex: Int = 0) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastPageIndex = lastPageIndex
    }

    /// Reading progress between 0 and 1.
    var progress: Double {
        guard pageCount > 1 else { return pageCount == 1 ? 1 : 0 }
        return Double(min(max(lastPageIndex, 0), pageCount - 1)) / Double(pageCount - 1)
    }
}

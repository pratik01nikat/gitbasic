import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    let open: (Book) -> Void

    @State private var isImporting = false
    @State private var importErrors: [String] = []
    @State private var renaming: Book?
    @State private var renameText = ""
    @State private var deleting: Book?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 28, alignment: .top)]

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("No Books Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Import a PDF to start reading, highlighting and writing notes with Apple Pencil.")
                    } actions: {
                        Button("Import PDF") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(library.books) { book in
                                Button { open(book) } label: {
                                    BookCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { menu(for: book) }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isImporting = true } label: {
                        Label("Import PDF", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .alert("Rename Book", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let book = renaming { library.rename(book, to: renameText) }
                }
            }
            .confirmationDialog("Delete this book?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { book in
                Button("Delete “\(book.title)”", role: .destructive) { library.delete(book) }
            } message: { _ in
                Text("The PDF, your handwriting, highlights, pins and whiteboards for this book will be removed.")
            }
            .alert("Some files couldn't be imported", isPresented: Binding(get: { !importErrors.isEmpty }, set: { if !$0 { importErrors = [] } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrors.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button { open(book) } label: { Label("Open", systemImage: "book") }
        Button {
            renameText = book.title
            renaming = book
        } label: { Label("Rename", systemImage: "pencil") }
        Button(role: .destructive) { deleting = book } label: { Label("Delete", systemImage: "trash") }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var errors: [String] = []
            var imported: [Book] = []
            for url in urls {
                do {
                    imported.append(try library.importPDF(from: url))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importErrors = errors
            // A single new book opens straight away.
            if urls.count == 1, let book = imported.first {
                open(book)
            }
        case .failure(let error):
            importErrors = [error.localizedDescription]
        }
    }
}

private struct BookCard: View {
    @EnvironmentObject private var library: LibraryStore
    let book: Book
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .aspectRatio(0.72, contentMode: .fit)
                        .overlay { ProgressView() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 260, alignment: .bottom)
            .overlay(alignment: .leading) {
                // A hint of a spine.
                LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 8)
                    .opacity(cover == nil ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    ProgressView(value: book.progress)
                        .tint(.accentColor)
                    Text(book.lastOpenedAt == nil ? "New" : "\(Int(book.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(book.pageCount) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: book.id) {
            cover = await library.cover(for: book, width: 200)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.pageCount) pages, \(Int(book.progress * 100)) percent read")
    }
}

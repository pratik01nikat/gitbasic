import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}

/// Library at the root; an open book covers it full screen.
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: BookSession?
    @State private var errorMessage: String?

    var body: some View {
        LibraryView(open: { open($0) })
            .fullScreenCover(item: $session) { session in
                BookWorkspaceView(session: session) {
                    session.saveNow()
                    self.session = nil
                }
            }
            .onOpenURL { importAndOpen($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { session?.saveNow() }
            }
            .alert("Couldn't Open Book", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func open(_ book: Book) {
        guard let newSession = BookSession(book: book, library: library) else {
            errorMessage = "“\(book.title)” could not be read. The file may be damaged."
            return
        }
        library.markOpened(book)
        session = newSession
    }

    /// PDFs shared to Folio from Files, Mail, Safari… are imported and opened.
    private func importAndOpen(_ url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else { return }
        do {
            let book = try library.importPDF(from: url)
            // Files handed over via "Open in" are copied into Documents/Inbox; tidy up.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            session?.saveNow()
            session = nil
            DispatchQueue.main.async { open(book) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

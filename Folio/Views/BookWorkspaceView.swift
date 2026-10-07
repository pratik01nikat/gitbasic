import SwiftUI

/// An open book: sidebar (pins, highlights, bookmarks, contents, whiteboards)
/// next to the reader, a whiteboard, or both side by side.
struct BookWorkspaceView: View {
    @ObservedObject var session: BookSession
    let close: () -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var exportedFile: ExportedFile?
    @State private var isExporting = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if session.showsToolPalette {
                    ToolPaletteView(session: session)
                        .background(Color(uiColor: Paper.desk))
                }
                content
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar { toolbar }
        }
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: session.toast)
        .background(PencilInteractionHost(session: session))
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .onChange(of: session.layout) { _, layout in
            if layout == .board && session.tool.kind == .textHighlight { session.select(.pen) }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            if session.layout != .board {
                VStack(spacing: 0) {
                    BookReaderView(session: session)
                    PageScrubber(session: session)
                }
                .frame(maxWidth: .infinity)
            }
            if session.layout != .book {
                if session.layout == .split { Divider() }
                Group {
                    if let board = session.activeBoard {
                        WhiteboardPane(session: session, board: board)
                    } else {
                        ContentUnavailableView {
                            Label("No Whiteboard", systemImage: "rectangle.and.pencil.and.ellipsis")
                        } actions: {
                            Button("New Whiteboard") { session.createBoard() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: close) {
                Label("Library", systemImage: "books.vertical")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if session.layout != .board {
                Button { session.toggleBookmarkForCurrentPage() } label: {
                    Label("Bookmark", systemImage: session.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                }
                .tint(session.isCurrentPageBookmarked ? .red : nil)
            }

            Picker("Layout", selection: layoutBinding) {
                Image(systemName: "book").accessibilityLabel("Book").tag(WorkspaceLayout.book)
                Image(systemName: "rectangle.split.2x1").accessibilityLabel("Book and Whiteboard").tag(WorkspaceLayout.split)
                Image(systemName: "rectangle.and.pencil.and.ellipsis").accessibilityLabel("Whiteboard").tag(WorkspaceLayout.board)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Button { export() } label: {
                if isExporting {
                    ProgressView()
                } else {
                    Label("Share Annotated PDF", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExporting)

            Menu {
                Toggle(isOn: $session.showsToolPalette) { Label("Show Tools", systemImage: "pencil.tip.crop.circle") }
                Toggle(isOn: $session.fingerDrawing) { Label("Draw with Finger", systemImage: "hand.draw") }
                Toggle(isOn: $session.twoPageSpread) { Label("Two Pages in Landscape", systemImage: "book.pages") }
                Toggle(isOn: $session.pageTurnHaptics) { Label("Page Turn Haptics", systemImage: "iphone.radiowaves.left.and.right") }
            } label: {
                Label("Settings", systemImage: "ellipsis.circle")
            }
        }
    }

    private var layoutBinding: Binding<WorkspaceLayout> {
        Binding(get: { session.layout }, set: { layout in
            if layout != .book && session.activeBoard == nil { session.createBoard() }
            session.layout = layout
        })
    }

    private func export() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                exportedFile = ExportedFile(url: try await session.exportAnnotatedPDF())
            } catch {
                session.showToast("Couldn't export: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }
}

/// Whiteboard header (switch board, paper style) above the canvas.
struct WhiteboardPane: View {
    @ObservedObject var session: BookSession
    let board: Whiteboard

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(session.annotations.boards) { other in
                        Button { session.openBoard(other.id) } label: {
                            Label(other.title, systemImage: other.id == board.id ? "checkmark" : "rectangle.and.pencil.and.ellipsis")
                        }
                    }
                    Divider()
                    Button {
                        let created = session.createBoard()
                        session.openBoard(created.id)
                    } label: { Label("New Whiteboard", systemImage: "plus") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        Text(board.title).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                }

                Spacer()

                Picker("Paper", selection: Binding(get: { board.background }, set: { session.setBackground($0, forBoard: board.id) })) {
                    ForEach(BoardBackground.allCases) { background in
                        Label(background.name, systemImage: background.symbol).tag(background)
                    }
                }
                .pickerStyle(.menu)

                if session.layout == .split {
                    Button { session.layout = .board } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Expand whiteboard")
                } else {
                    Button { session.layout = .split } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .accessibilityLabel("Show book beside whiteboard")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            WhiteboardCanvasView(session: session, boardID: board.id)
                .id(board.id)
        }
    }
}

struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Apple Pencil double-tap (and squeeze on Apple Pencil Pro) follows the
/// action chosen in iPadOS Settings: switch to the eraser, or to the last tool.
struct PencilInteractionHost: UIViewRepresentable {
    let session: BookSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let session: BookSession

        init(session: BookSession) {
            self.session = session
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            perform(UIPencilInteraction.preferredTapAction)
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            perform(UIPencilInteraction.preferredTapAction)
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            perform(UIPencilInteraction.preferredSqueezeAction)
        }

        private func perform(_ action: UIPencilPreferredAction) {
            switch action {
            case .switchEraser: session.toggleEraser()
            case .switchPrevious: session.switchToPreviousTool()
            default: break
            }
        }
    }
}

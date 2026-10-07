import SwiftUI

struct SidebarView: View {
    @ObservedObject var session: BookSession

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $session.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.symbol)
                        .accessibilityLabel(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            switch session.sidebarTab {
            case .pins: PinsList(session: session)
            case .highlights: HighlightsList(session: session)
            case .bookmarks: BookmarksList(session: session)
            case .contents: ContentsList(session: session)
            case .boards: BoardsList(session: session)
            }
        }
        .navigationTitle(session.sidebarTab.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pins

private struct PinsList: View {
    @ObservedObject var session: BookSession
    @State private var renaming: Pin?
    @State private var renameText = ""

    var body: some View {
        List {
            ForEach(session.sortedPins) { pin in
                Button { session.open(pin) } label: {
                    PinRow(session: session, pin: pin)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        renameText = pin.title
                        renaming = pin
                    } label: { Label("Rename", systemImage: "pencil") }
                    Menu {
                        ForEach(PinColor.allCases) { color in
                            Button { session.setPinColor(pin.id, color) } label: {
                                Label(color.name, systemImage: color == pin.color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: { Label("Color", systemImage: "paintpalette") }
                    Button(role: .destructive) { session.deletePin(pin.id) } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) { session.deletePin(pin.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onMove { session.movePins(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .overlay {
            if session.annotations.pins.isEmpty {
                ContentUnavailableView {
                    Label("No Pinned Notes", systemImage: "pin")
                } description: {
                    Text("Choose the Pin tool, then tap your handwriting on a page or whiteboard. Each pin gets a number and shows up here.")
                } actions: {
                    Button("Choose Pin Tool") { session.select(.pin) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !session.annotations.pins.isEmpty {
                    Menu {
                        Button { session.renumberPinsByPageOrder() } label: {
                            Label("Renumber in Page Order", systemImage: "list.number")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    EditButton()
                }
            }
        }
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let pin = renaming { session.renamePin(pin.id, to: renameText) }
            }
        }
    }
}

private struct PinRow: View {
    @ObservedObject var session: BookSession
    let pin: Pin
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(pin.number)")
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, pin.number > 99 ? 4 : 0)
                .background(Color(uiColor: pin.color.uiColor), in: Capsule())

            VStack(alignment: .leading, spacing: 6) {
                Text(pin.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color(uiColor: .secondarySystemFill))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 90, alignment: .leading)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))

                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(session.surfaceName(pin.surface))
                    Text("·")
                    Text(pin.createdAt, format: .dateTime.day().month(.abbreviated))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: "\(pin.id)-\(pin.rect.debugDescription)-\(session.inkRevision)") {
            thumbnail = await session.snapshot(of: pin, maxPixels: 600)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note \(pin.number), \(pin.title), \(session.surfaceName(pin.surface))")
    }

    private var icon: String {
        if case .board = pin.surface { return "rectangle.and.pencil.and.ellipsis" }
        return "doc.text"
    }

    /// Wide notes get a short strip, tall notes a taller box.
    private var thumbnailHeight: CGFloat {
        let ratio = pin.rect.height / max(pin.rect.width, 1)
        return min(90, max(44, 230 * ratio))
    }
}

// MARK: - Highlights

private struct HighlightsList: View {
    @ObservedObject var session: BookSession

    var body: some View {
        List {
            ForEach(session.sortedHighlights) { highlight in
                Button { session.open(highlight) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(uiColor: highlight.color.uiColor))
                            .frame(width: 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("“\(highlight.text)”")
                                .font(.callout)
                                .italic()
                                .lineLimit(5)
                            Text(session.pageLabel(highlight.pageIndex))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { UIPasteboard.general.string = highlight.text } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    Menu {
                        ForEach(MarkColor.allCases) { color in
                            Button { session.setHighlightColor(highlight.id, color) } label: {
                                Label(color.name, systemImage: color == highlight.color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: { Label("Color", systemImage: "paintpalette") }
                    Button(role: .destructive) { session.deleteHighlight(highlight.id) } label: { Label("Remove", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) { session.deleteHighlight(highlight.id) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if session.annotations.highlights.isEmpty {
                ContentUnavailableView {
                    Label("No Highlights", systemImage: "highlighter")
                } description: {
                    Text("Choose Highlight Text and drag across a sentence. The highlight snaps to the words.")
                } actions: {
                    Button("Choose Highlight Text") { session.select(.textHighlight) }
                }
            }
        }
    }
}

// MARK: - Bookmarks

private struct BookmarksList: View {
    @ObservedObject var session: BookSession

    var body: some View {
        List {
            ForEach(session.annotations.bookmarks, id: \.self) { page in
                Button { session.goToPage(page) } label: {
                    HStack(spacing: 12) {
                        PageThumbnail(session: session, page: page)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.pageLabel(page)).font(.subheadline.weight(.semibold))
                            if session.pagesWithInk.contains(page) {
                                Label("Has handwriting", systemImage: "pencil.tip")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "bookmark.fill").foregroundStyle(.red)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { session.removeBookmark(page) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if session.annotations.bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                       description: Text("Tap the bookmark button in the top bar to mark the page you're on."))
            }
        }
    }
}

private struct PageThumbnail: View {
    @ObservedObject var session: BookSession
    let page: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color(uiColor: .secondarySystemFill))
            }
        }
        .frame(width: 44, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .task(id: page) {
            image = await session.pageThumbnail(page, width: 44)
        }
    }
}

// MARK: - Contents

private struct ContentsList: View {
    @ObservedObject var session: BookSession

    var body: some View {
        List(session.outline, children: \.children) { item in
            Button {
                if let page = item.pageIndex { session.goToPage(page) }
            } label: {
                HStack {
                    Text(item.title).lineLimit(2)
                    Spacer()
                    if let page = item.pageIndex {
                        Text("\(page + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.pageIndex == nil)
        }
        .listStyle(.plain)
        .overlay {
            if session.outline.isEmpty {
                ContentUnavailableView("No Table of Contents", systemImage: "list.bullet.indent",
                                       description: Text("This PDF doesn't include one. Use the page slider or bookmarks to get around."))
            }
        }
    }
}

// MARK: - Whiteboards

private struct BoardsList: View {
    @ObservedObject var session: BookSession
    @State private var renaming: Whiteboard?
    @State private var renameText = ""
    @State private var deleting: Whiteboard?

    var body: some View {
        List {
            Section {
                Button {
                    let board = session.createBoard()
                    session.openBoard(board.id)
                } label: {
                    Label("New Whiteboard", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            Section {
                ForEach(session.annotations.boards) { board in
                    Button { session.openBoard(board.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: board.background.symbol)
                                .frame(width: 36, height: 36)
                                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(board.title).font(.subheadline.weight(.semibold))
                                let pins = session.annotations.pins(on: .board(board.id)).count
                                Text("\(board.updatedAt, format: .relative(presentation: .named))\(pins > 0 ? " · \(pins) pinned" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if board.id == session.activeBoardID && session.layout != .book {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameText = board.title
                            renaming = board
                        } label: { Label("Rename", systemImage: "pencil") }
                        Menu {
                            ForEach(BoardBackground.allCases) { background in
                                Button { session.setBackground(background, forBoard: board.id) } label: {
                                    Label(background.name, systemImage: background == board.background ? "checkmark" : background.symbol)
                                }
                            }
                        } label: { Label("Paper", systemImage: "doc.richtext") }
                        Button(role: .destructive) { deleting = board } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .alert("Rename Whiteboard", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let board = renaming { session.renameBoard(board.id, to: renameText) }
            }
        }
        .confirmationDialog("Delete this whiteboard?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { board in
            Button("Delete “\(board.title)”", role: .destructive) { session.deleteBoard(board.id) }
        } message: { _ in
            Text("Its handwriting and pins will be removed.")
        }
    }
}

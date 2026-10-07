import SwiftUI

/// Floating tool bar: tools, the current tool's options, undo/redo and the
/// finger-drawing switch.
struct ToolPaletteView: View {
    @ObservedObject var session: BookSession
    @State private var showsOptions = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            palette
            ScrollView(.horizontal, showsIndicators: false) { palette }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private var palette: some View {
        HStack(spacing: 2) {
            ForEach(ToolKind.allCases) { kind in
                let enabled = kind != .textHighlight || session.layout != .board
                Button {
                    if session.tool.kind == kind, hasOptions(kind) {
                        showsOptions.toggle()
                    } else {
                        session.select(kind)
                    }
                } label: {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 40, height: 36)
                        .background(session.tool.kind == kind ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(session.tool.kind == kind ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .help(kind.title)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(session.tool.kind == kind ? .isSelected : [])
            }

            if hasOptions(session.tool.kind) {
                divider
                Button { showsOptions.toggle() } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(currentColor)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 36)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tool options")
                .popover(isPresented: $showsOptions, arrowEdge: .top) {
                    ToolOptionsView(session: session)
                        .padding(20)
                        .frame(width: 320)
                }
            }

            divider
            iconButton("arrow.uturn.backward", label: "Undo") { session.undo() }
            iconButton("arrow.uturn.forward", label: "Redo") { session.redo() }
            divider
            iconButton(session.fingerDrawing ? "hand.draw.fill" : "hand.draw",
                       label: session.fingerDrawing ? "Finger drawing on" : "Finger drawing off",
                       tint: session.fingerDrawing ? .accentColor : .primary) {
                session.fingerDrawing.toggle()
                session.showToast(session.fingerDrawing ? "Finger draws · use the slider to turn pages" : "Apple Pencil draws · finger turns pages",
                                  symbol: "hand.draw")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .fixedSize()
    }

    private var divider: some View {
        Divider().frame(height: 24).padding(.horizontal, 4)
    }

    private func iconButton(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 36)
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func hasOptions(_ kind: ToolKind) -> Bool {
        switch kind {
        case .pen, .marker, .textHighlight, .eraser, .pin: return true
        case .read, .lasso: return false
        }
    }

    private var currentColor: Color {
        let tool = session.tool
        switch tool.kind {
        case .pen: return Color(uiColor: tool.inkColor.uiColor)
        case .marker, .textHighlight: return Color(uiColor: tool.markColor.uiColor)
        case .pin: return Color(uiColor: tool.pinColor.uiColor)
        case .eraser: return Color(uiColor: .systemGray3)
        case .read, .lasso: return .clear
        }
    }
}

struct ToolOptionsView: View {
    @ObservedObject var session: BookSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(session.tool.kind.title).font(.headline)
            switch session.tool.kind {
            case .pen:
                Picker("Pen", selection: $session.tool.penStyle) {
                    ForEach(PenStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                SwatchRow(values: InkColor.allCases, selection: $session.tool.inkColor) { Color(uiColor: $0.uiColor) }
                SizeRow(selection: $session.tool.penSize, color: Color(uiColor: session.tool.inkColor.uiColor))
            case .marker:
                SwatchRow(values: MarkColor.allCases, selection: $session.tool.markColor) { Color(uiColor: $0.uiColor) }
                SizeRow(selection: $session.tool.markerSize, color: Color(uiColor: session.tool.markColor.uiColor))
            case .textHighlight:
                SwatchRow(values: MarkColor.allCases, selection: $session.tool.markColor) { Color(uiColor: $0.uiColor) }
                hint("Drag across text with Apple Pencil or your finger. Tap a highlight to recolor, copy or remove it.")
            case .eraser:
                Picker("Eraser", selection: $session.tool.eraser) {
                    ForEach(EraserStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                hint("The stroke eraser removes whole strokes; the pixel eraser rubs out only what it touches.")
            case .pin:
                SwatchRow(values: PinColor.allCases, selection: $session.tool.pinColor) { Color(uiColor: $0.uiColor) }
                hint("Tap your handwriting to pin the whole note, or drag a box around exactly what you want. Pins are numbered and listed in the sidebar.")
            case .read, .lasso:
                EmptyView()
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of round color swatches.
struct SwatchRow<Value: Hashable & Identifiable>: View {
    let values: [Value]
    @Binding var selection: Value
    let color: (Value) -> Color

    var body: some View {
        HStack(spacing: 12) {
            ForEach(values) { value in
                Button { selection = value } label: {
                    Circle()
                        .fill(color(value))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selection == value ? Color.accentColor : .clear, lineWidth: 2.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(describing: value.id).capitalized)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

struct SizeRow: View {
    @Binding var selection: StrokeSize
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            ForEach(StrokeSize.allCases) { size in
                Button { selection = size } label: {
                    Circle()
                        .fill(color)
                        .frame(width: size.dot, height: size.dot)
                        .frame(width: 44, height: 36)
                        .background(selection == size ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(size.name)
                .accessibilityAddTraits(selection == size ? .isSelected : [])
            }
        }
    }
}

/// Page slider and arrows along the bottom of the book.
struct PageScrubber: View {
    @ObservedObject var session: BookSession
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { session.turnPage(forward: false) } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled((session.visiblePages.first ?? session.currentPage) <= 0)
            .accessibilityLabel("Previous page")

            if session.pageCount > 1 {
                Slider(
                    value: Binding(get: { dragValue ?? Double(session.currentPage) }, set: { dragValue = $0 }),
                    in: 0...Double(session.pageCount - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing, let value = dragValue {
                            session.goToPage(Int(value.rounded()), animated: false)
                            dragValue = nil
                        }
                    }
                )
                .accessibilityLabel("Page")
                .accessibilityValue(label)
            } else {
                Spacer()
            }

            Text(label)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 130, alignment: .trailing)

            Button { session.turnPage(forward: true) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 32)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled((session.visiblePages.last ?? session.currentPage) >= session.pageCount - 1)
            .accessibilityLabel("Next page")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var label: String {
        if let dragValue {
            return "\(session.pageLabel(Int(dragValue.rounded()))) of \(session.pageCount)"
        }
        let pages = session.visiblePages
        if pages.count > 1, let first = pages.first, let last = pages.last {
            return "Pages \(first + 1)–\(last + 1) of \(session.pageCount)"
        }
        return "\(session.pageLabel(session.currentPage)) of \(session.pageCount)"
    }
}

/// Short confirmation bubble ("Pinned note 3").
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

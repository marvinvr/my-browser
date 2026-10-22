import SwiftUI

enum SpaceEditorMode: Identifiable {
    case create
    case edit(Space)

    var id: String {
        switch self {
        case .create:
            "create"
        case .edit(let space):
            "edit-\(space.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create: "New Space"
        case .edit: "Edit Space"
        }
    }

    var confirmTitle: String {
        switch self {
        case .create: "Create"
        case .edit: "Save"
        }
    }
}

/// Name, SF Symbol, and color for creating or editing a space.
struct SpaceEditor: View {
    var mode: SpaceEditorMode

    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    @State private var name: String
    @State private var symbol: String
    @State private var color: SpaceColor

    init(mode: SpaceEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "New Space")
            _symbol = State(initialValue: "star.fill")
            _color = State(initialValue: .teal)
        case .edit(let space):
            _name = State(initialValue: space.name)
            _symbol = State(initialValue: space.symbol)
            _color = State(initialValue: space.color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(.title3.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(symbols, id: \.self) { candidate in
                        symbolButton(candidate)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(SpaceColor.allCases, id: \.self) { candidate in
                        colorButton(candidate)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glass)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var symbols: [String] {
        var list = SpaceSymbols.curated
        if !list.contains(symbol) {
            list.insert(symbol, at: 0)
        }
        return list
    }

    private func symbolButton(_ candidate: String) -> some View {
        let selected = candidate == symbol
        return Button {
            symbol = candidate
        } label: {
            Image(systemName: candidate)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .foregroundStyle(selected ? color.color : .secondary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(color.color.opacity(0.16))
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(color.color.opacity(0.85), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func colorButton(_ candidate: SpaceColor) -> some View {
        let selected = candidate == color
        return Button {
            color = candidate
        } label: {
            ZStack {
                if selected {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                }
                Circle()
                    .fill(candidate.color)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .create:
            let space = model.createSpace(name: trimmed, symbol: symbol, color: color)
            model.selectSpace(space.id)
        case .edit(let space):
            model.renameSpace(space.id, to: trimmed)
            model.library.updateSpace(space.id) { draft in
                draft.symbol = symbol
                draft.color = color
            }
        }
        dismiss()
    }
}

enum SpaceSymbols {
    /// A short curated set. Imported spaces may use a symbol outside this list; the editor keeps it.
    static let curated: [String] = [
        "star.fill",
        "person.fill",
        "briefcase.fill",
        "house.fill",
        "book.fill",
        "graduationcap.fill",
        "gamecontroller.fill",
        "music.note",
        "heart.fill",
        "bolt.fill",
        "leaf.fill",
        "airplane",
        "cart.fill",
        "paintbrush.fill",
        "camera.fill",
        "bubble.left.fill",
        "globe",
        "moon.fill",
        "cup.and.saucer.fill",
        "folder.fill",
    ]
}

#if DEBUG
#Preview("New Space") {
    PreviewHost {
        SpaceEditor(mode: .create)
    }
}
#endif

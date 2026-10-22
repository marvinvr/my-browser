import SwiftUI

/// Sheet for renaming an item or naming a new folder.
struct NamePrompt: View {
    var title: String
    var confirmTitle: String
    @State private var name: String
    var onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(title: String, confirmTitle: String, initialName: String, onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glass)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

struct SidebarPrompt: Identifiable {
    enum Kind {
        case rename(UUID)
        case newFolder(parentID: UUID?)
    }

    let id = UUID()
    var kind: Kind
    var initialName: String

    var title: String {
        switch kind {
        case .rename: "Rename"
        case .newFolder: "New Folder"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .rename: "Rename"
        case .newFolder: "Create"
        }
    }
}

import AppKit
import SwiftUI

/// Single-line field that becomes first responder when shown.
/// In edit-current mode the existing URL is selected. Up/Down move the result list.
struct CommandBarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var selectsAll: Bool
    var onSubmit: () -> Void
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.sendsActionOnEndEditing = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.wraps = false
            cell.usesSingleLineMode = true
        }
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        guard !context.coordinator.didFocus else { return }
        context.coordinator.didFocus = true
        context.coordinator.focus(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 580, height: 26)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandBarTextField
        weak var field: NSTextField?
        var didFocus = false

        init(_ parent: CommandBarTextField) {
            self.parent = parent
        }

        func focus(_ field: NSTextField, attempt: Int = 0) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                guard field.window != nil else {
                    if attempt < 6 { self.focus(field, attempt: attempt + 1) }
                    return
                }
                field.window?.makeFirstResponder(field)
                if self.parent.selectsAll {
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}

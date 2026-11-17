import AppKit
import SwiftUI

/// Places the insertion point after the character that opened the sheet, rather
/// than selecting it (the default focus behavior of a native text field).
struct InstrumentSearchField: NSViewRepresentable {
    @Binding var text: String
    var submit: () -> Void
    var move: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Ticker or company name"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.input = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
    }
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: InstrumentSearchField
        init(_ input: InstrumentSearchField) { self.input = input }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { input.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)): input.submit(); return true
            case #selector(NSResponder.moveDown(_:)): input.move(1); return true
            case #selector(NSResponder.moveUp(_:)): input.move(-1); return true
            default: return false
            }
        }
    }
}

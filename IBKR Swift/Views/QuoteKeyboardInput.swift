import AppKit
import SwiftUI

/// Window-scoped typing trigger; the monitor is removed when Quote leaves the hierarchy.
struct QuoteKeyboardInput: NSViewRepresentable {
    var isSearching: Bool
    var typed: (String) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.input = self
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var input: QuoteKeyboardInput?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSTextField),
                      let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "." }),
                      // Digits and punctuation retain the chart's zoom/reset shortcuts.
                      (self.input?.isSearching == true || chars.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })) else { return event }
                self.input?.typed(chars)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

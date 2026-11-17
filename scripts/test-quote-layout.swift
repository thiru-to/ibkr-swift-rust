// Build the app in Debug, then compile this check against that build:
// xcrun swiftc -parse-as-library scripts/test-quote-layout.swift \
//   -I "$PRODUCTS" -I "$PRODUCTS/include" \
//   -Xlinker "$PRODUCTS/IBKR Swift.app/Contents/MacOS/IBKR Swift.debug.dylib" \
//   -Xlinker -rpath -Xlinker "$PRODUCTS/IBKR Swift.app/Contents/MacOS" \
//   -o /tmp/test-quote-layout
// /tmp/test-quote-layout
import AppKit
import SwiftUI
@testable import IBKR_Swift

@main
struct QuoteLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        // Sizes of the detail column at the minimum, default, and larger windows.
        for size in [NSSize(width: 860, height: 600),
                     NSSize(width: 1036, height: 728),
                     NSSize(width: 1600, height: 1000)] {
            let host = NSHostingView(rootView: QuoteView().environment(AppStore()))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))

            // Checking fittingSize alone misses this bug: AppKit uses the hosting
            // view's minimum sizing pass to enlarge the actual window/content.
            let actual = host.frame.size
            guard actual.width <= size.width + 1, actual.height <= size.height + 1 else {
                print("FAIL: Quote expanded from \(size) to \(actual)")
                exit(1)
            }
            print("PASS: Quote fits \(size)")
        }
    }
}

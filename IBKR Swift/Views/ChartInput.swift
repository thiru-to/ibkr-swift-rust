//
//  ChartInput.swift
//  IBKR Swift
//

import AppKit
import SwiftUI

/// Pointer and keyboard input for a pannable/zoomable chart, from an AppKit view laid
/// over it. SwiftUI's DragGesture, focus and event-monitor routes all proved unreliable
/// over a Swift Chart (Charts rebuilds its overlay as the view moves), so the view
/// receives the events itself: nothing to install or tear down.
struct ChartInput: NSViewRepresentable {
    enum Key {
        case left, right, zoomIn, zoomOut, reset
    }

    /// Horizontal movement in points; positive moves the content right.
    var pan: (CGFloat) -> Void
    /// Zoom factor (>1 = in) around an x position in this view's coordinates.
    var zoom: (Double, CGFloat) -> Void
    var key: (Key) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.input = self
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.input = self
    }

    final class InputView: NSView {
        var input: ChartInput?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        private func x(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            input?.pan(event.deltaX)
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
        }

        /// Mostly-sideways scrolls pan; mostly-vertical ones (and a mouse wheel) zoom.
        override func scrollWheel(with event: NSEvent) {
            // A mouse wheel reports lines, not points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let dx = event.scrollingDeltaX * scale
            let dy = event.scrollingDeltaY * scale
            if abs(dx) > abs(dy) {
                input?.pan(dx)
            } else if dy != 0 {
                input?.zoom(exp(Double(dy) * 0.005), x(event))
            }
        }

        override func magnify(with event: NSEvent) {
            input?.zoom(1 + event.magnification, x(event))
        }

        override func keyDown(with event: NSEvent) {
            let key: Key? = switch (event.keyCode, event.charactersIgnoringModifiers) {
            case (123, _): .left
            case (124, _): .right
            case (_, "+"), (_, "="): .zoomIn
            case (_, "-"): .zoomOut
            case (_, "0"): .reset
            default: nil
            }
            if let key { input?.key(key) } else { super.keyDown(with: event) }
        }
    }
}

import SwiftUI
import AppKit

/// Bridges to the hosting `NSWindow` so SwiftUI can apply one-time window setup
/// (e.g. open maximized).
///
/// `view.window` may still be nil on the first run-loop turn after creation, so
/// we retry briefly until the window is attached. The configuration is
/// idempotent, so a rare re-creation re-applying it is harmless. Note: applying
/// `setFrame` intentionally overrides any state-restored frame ("always opens
/// maximized").
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let apply = configure
        func attempt(_ retriesRemaining: Int) {
            DispatchQueue.main.async {
                if let window = view.window {
                    apply(window)
                } else if retriesRemaining > 0 {
                    attempt(retriesRemaining - 1)
                }
            }
        }
        attempt(10)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

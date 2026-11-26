import SwiftUI

extension View {
    /// Escape closes the window this view fills (Settings, Keyboard
    /// Shortcuts, Command Line Tool), whatever has focus. `onExitCommand`
    /// alone isn't enough: these windows open with nothing focused (the
    /// window itself is first responder), and then Escape never reaches it.
    /// A Cancel key equivalent is tried before the focused control gets the
    /// key, so `action` decides what Escape does first (Keyboard Shortcuts
    /// clears its filter before it closes).
    func escapeCloses(_ action: @escaping () -> Void) -> some View {
        background {
            Button("Close", action: action)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .focusable(false) // never a Tab stop
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

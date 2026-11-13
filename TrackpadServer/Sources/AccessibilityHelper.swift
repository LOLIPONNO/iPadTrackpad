import AppKit
import ApplicationServices
import Foundation

/// Checks and requests macOS Accessibility (`AXIsProcessTrustedWithOptions`) permissions
/// required for `CGEvent.post(tap: .cghidEventTap)` cursor, scroll, and gesture injection.
enum AccessibilityHelper {
    /// Returns `true` if the current process is already trusted for Accessibility event injection.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Checks Accessibility trust and optionally presents the native macOS system prompt.
    @discardableResult
    static func checkAndPromptIfNeeded(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Deep-links directly to System Settings > Privacy & Security > Accessibility.
    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

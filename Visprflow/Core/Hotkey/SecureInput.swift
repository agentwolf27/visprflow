import Carbon.HIToolbox
import Foundation

/// Secure Event Input is what a password field, or Terminal with "Secure Keyboard Entry" on,
/// switches on to stop anything reading the keyboard. While it is active a CGEventTap stops
/// receiving key events entirely, though modifier changes still arrive, which is why the
/// trigger key is a modifier (fn) rather than a letter chord.
enum SecureInput {
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// The process holding secure input, when it can be identified. Useful for telling the
    /// user *which* app is blocking insertion rather than just that something is.
    static var holderName: String? {
        // There is no public API for this; the frontmost app is the best available guess.
        guard isActive else { return nil }
        return NSWorkspaceHelper.frontmostAppName
    }
}

import AppKit

private enum NSWorkspaceHelper {
    @MainActor
    static var frontmostAppNameMain: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    nonisolated static var frontmostAppName: String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { frontmostAppNameMain }
        }
        return nil
    }
}

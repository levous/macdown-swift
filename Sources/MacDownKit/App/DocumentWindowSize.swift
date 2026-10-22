//
//  DocumentWindowSize.swift
//  MacDown
//
//  Remembers the size the user last gave a document window, so new windows
//  open at that size (if it fits the screen) instead of SwiftUI's default.
//

import AppKit

@MainActor
enum DocumentWindowSize {
    /// Window state, not a preference: there is no setting for it.
    static let key = "documentWindowSize"

    /// The remembered window size (its frame, title bar and toolbar
    /// included, which is what `WindowPlacement` sizes), if one was saved.
    static func saved(in defaults: UserDefaults = .standard) -> CGSize? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let size = NSSizeFromString(string)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// The remembered window size, if it fits in `visibleFrame` (a screen's
    /// frame minus the menu bar and Dock).
    static func size(fitting visibleFrame: CGRect,
                     in defaults: UserDefaults = .standard) -> CGSize? {
        guard let size = saved(in: defaults),
              size.width <= visibleFrame.width,
              size.height <= visibleFrame.height
        else { return nil }
        return size
    }

    /// Remembers the window's size after the user resized it.
    static func save(from window: NSWindow, in defaults: UserDefaults = .standard) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        defaults.set(NSStringFromSize(window.frame.size), forKey: key)
    }
}

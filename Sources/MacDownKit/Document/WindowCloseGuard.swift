//
//  WindowCloseGuard.swift
//  MacDown
//
//  SwiftUI has no public way to veto closing a document window, so this
//  wraps the window's delegate (SwiftUI's) in an object that answers
//  windowShouldClose(_:) first and forwards every other delegate message to
//  the original.
//

import AppKit

@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    /// SwiftUI's delegate. NSWindow.delegate is weak, so this keeps it alive
    /// while the guard stands in for it.
    // Set on the main thread; also read by NSObject's (nonisolated)
    // forwarding methods, which AppKit calls there too.
    nonisolated(unsafe) private(set) var original: NSWindowDelegate?
    /// Decides whether the window may close now. Returning false cancels
    /// this close; the decision can close the window later with
    /// `closeWithoutAsking(_:)`.
    var shouldClose: (NSWindow) -> Bool
    /// Closes the window once the question is answered. Replaceable for
    /// tests: performClose(_:) animates the close button in a nested event
    /// loop, which doesn't mix with a test runner's main run loop.
    var closeWindow: (NSWindow) -> Void = { $0.performClose(nil) }

    private var bypass = false
    private var delegateObservation: NSKeyValueObservation?

    init(shouldClose: @escaping (NSWindow) -> Bool) {
        self.shouldClose = shouldClose
    }

    /// Puts the guard in front of the window's current delegate, and again
    /// whenever the delegate is replaced.
    func install(on window: NSWindow) {
        wrap(window)
        delegateObservation = window.observe(\.delegate) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.wrap(window) }
        }
    }

    func uninstall(from window: NSWindow?) {
        delegateObservation = nil
        if let window, window.delegate === self {
            window.delegate = original
        }
        original = nil
    }

    private func wrap(_ window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        // NSWindow caches which delegate methods exist when it's assigned,
        // so set the guard after `original` (respondsToSelector depends on it).
        window.delegate = self
    }

    /// Closes the window, skipping the guard's own question. Waits for the
    /// current event to finish, so it never starts a close from inside one
    /// AppKit is still handling (an answer may come back immediately).
    func closeWithoutAsking(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.bypass = true
            defer { self.bypass = false }
            self.closeWindow(window)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !bypass && !shouldClose(sender) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    // MARK: Forwarding

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}

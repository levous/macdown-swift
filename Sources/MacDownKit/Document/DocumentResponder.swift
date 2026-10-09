//
//  DocumentResponder.swift
//  MacDown
//
//  File ▸ Save (⌘S) is AppKit's saveDocument: action, sent up the responder
//  chain to the window's NSDocument. The document only holds the saved text
//  (the editor edits a draft; see DocumentController), so this responder
//  handles the action first and saves the draft. SwiftUI's window hands the
//  action to the document (as its supplemental target), so the responder
//  has to come before the window: it goes right after the last responder
//  ahead of it, which every focused view's chain passes. In SwiftUI windows
//  that's the content view controller:
//
//      … › AppKitWindowHostingView › AppKitWindowHostingController
//        › DocumentResponder › AppKitWindow › …
//

import AppKit

@MainActor
final class DocumentResponder: NSResponder {
    private weak var controller: DocumentController?
    private var chainObservation: NSKeyValueObservation?

    init(controller: DocumentController) {
        self.controller = controller
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The responder the chain goes through just before the window.
    private weak var anchor: NSResponder?

    /// Inserts the responder just before `window` in its responder chain,
    /// and again if something else takes its place.
    func install(in window: NSWindow) {
        guard let anchor = window.contentViewController ?? window.contentView else { return }
        self.anchor = anchor
        insert(after: anchor)
        chainObservation = anchor.observe(\.nextResponder) { [weak self] anchor, _ in
            MainActor.assumeIsolated { self?.insert(after: anchor) }
        }
    }

    func uninstall() {
        chainObservation = nil
        if let anchor, anchor.nextResponder === self {
            anchor.nextResponder = nextResponder
        }
        anchor = nil
    }

    private func insert(after anchor: NSResponder) {
        guard anchor.nextResponder !== self else { return }
        nextResponder = anchor.nextResponder
        anchor.nextResponder = self
    }

    @objc func saveDocument(_ sender: Any?) {
        controller?.save()
    }

    override func responds(to selector: Selector!) -> Bool {
        // Without a controller, let the action reach the document.
        if selector == #selector(saveDocument(_:)) { return controller != nil }
        return super.responds(to: selector)
    }
}

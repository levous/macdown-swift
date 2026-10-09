//
//  DocumentSaving.swift
//  MacDown
//
//  Asks about unsaved changes when a document window closes or the app
//  quits.
//
//  With "Save changes automatically" off, each window edits a draft (see
//  DocumentController's "Draft" section) and the document only receives it
//  when saved, so AppKit and SwiftUI consider the document unchanged. These
//  questions are therefore asked here: closing through WindowCloseGuard, and
//  quitting through the app delegate's applicationShouldTerminate(_:).
//

import AppKit

@MainActor
enum DocumentSaving {
    /// What to do with unsaved changes.
    enum UnsavedChangesChoice {
        case save
        case discard
        /// Don't close or quit; leave the documents as they are.
        case cancel
    }

    /// Asks about unsaved changes in the named documents when quitting.
    /// Replaceable for tests.
    static var askBeforeQuitting: @MainActor ([String]) -> UnsavedChangesChoice = runQuitAlert
    /// Asks about unsaved changes in a window that is closing, and reports
    /// the choice. Replaceable for tests.
    static var askBeforeClosing: @MainActor (
        NSWindow, String, @escaping (UnsavedChangesChoice) -> Void) -> Void = runCloseAlert

    // MARK: - Closing

    /// Whether `controller`'s window may close now. If its draft has unsaved
    /// changes, asks, and closes the window itself once saved or discarded.
    static func windowShouldClose(_ window: NSWindow,
                                  controller: DocumentController,
                                  closeGuard: WindowCloseGuard) -> Bool {
        guard controller.hasUnsavedChanges else { return true }
        func handle(_ choice: UnsavedChangesChoice) {
            switch choice {
            case .save:
                controller.save { saved in
                    if saved { closeGuard.closeWithoutAsking(window) }
                }
            case .discard:
                controller.discardDraft()
                closeGuard.closeWithoutAsking(window)
            case .cancel:
                break
            }
        }
        askBeforeClosing(window, controller.displayName) { choice in
            // Act once AppKit has finished this close request: NSDocument
            // won't save from inside it, and the answer may come back
            // before windowShouldClose(_:) returns.
            DispatchQueue.main.async { handle(choice) }
        }
        return false
    }

    // MARK: - Quitting

    /// Asks about unsaved drafts in `controllers`, saves or discards them,
    /// then calls `completion` with whether to quit. Returns false (and
    /// doesn't call `completion`) when nothing needs asking.
    static func reviewBeforeQuitting(_ controllers: [DocumentController],
                                     completion: @escaping (Bool) -> Void) -> Bool {
        let unsaved = controllers.filter(\.hasUnsavedChanges)
        guard !unsaved.isEmpty else { return false }
        switch askBeforeQuitting(unsaved.map(\.displayName)) {
        case .save:
            saveInTurn(unsaved, completion: completion)
        case .discard:
            unsaved.forEach { $0.discardDraft() }
            completion(true)
        case .cancel:
            completion(false)
        }
        return true
    }

    /// Saves each controller's draft in turn (each may show a save panel),
    /// stopping at the first that isn't saved.
    static func saveInTurn(_ controllers: [DocumentController],
                           completion: @escaping (Bool) -> Void) {
        guard let first = controllers.first else {
            completion(true)
            return
        }
        first.save { saved in
            guard saved else { return completion(false) }
            saveInTurn(Array(controllers.dropFirst()), completion: completion)
        }
    }

    // MARK: - The alert

    /// "You have unsaved changes." with a save button titled `saveTitle`,
    /// "Discard" (red) and "Cancel".
    static func makeAlert(saveTitle: String, names: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "You have unsaved changes.")
        alert.informativeText = names.joined(separator: "\n")
        alert.addButton(withTitle: saveTitle)
        let discard = alert.addButton(withTitle: String(localized: "Discard"))
        discard.hasDestructiveAction = true
        // NSAlert gives a button titled "Cancel" the Escape key.
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    static func choice(for response: NSApplication.ModalResponse) -> UnsavedChangesChoice {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private static func runQuitAlert(_ names: [String]) -> UnsavedChangesChoice {
        let alert = makeAlert(saveTitle: String(localized: "Save and Quit"), names: names)
        return choice(for: alert.runModal())
    }

    private static func runCloseAlert(_ window: NSWindow, _ name: String,
                                      completion: @escaping (UnsavedChangesChoice) -> Void) {
        let alert = makeAlert(saveTitle: String(localized: "Save"), names: [name])
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(choice(for: response)) }
        }
    }
}

/// Turns NSDocument's delegate-and-selector save callback into a closure.
@MainActor
final class DocumentSaveCallback: NSObject {
    private let completion: (Bool) -> Void
    private var keepAlive: DocumentSaveCallback?

    private init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    /// Saves `document` like File ▸ Save (a save panel if it's untitled).
    static func save(_ document: NSDocument, completion: @escaping (Bool) -> Void) {
        let callback = DocumentSaveCallback(completion)
        callback.keepAlive = callback
        document.save(withDelegate: callback,
                      didSave: #selector(document(_:didSave:contextInfo:)),
                      contextInfo: nil)
    }

    /// Saves `document` to a new file chosen in a save panel, like
    /// File ▸ Save As…; the document then refers to the new file.
    static func saveAs(_ document: NSDocument, completion: @escaping (Bool) -> Void) {
        let callback = DocumentSaveCallback(completion)
        callback.keepAlive = callback
        document.runModalSavePanel(for: .saveAsOperation, delegate: callback,
                                   didSave: #selector(document(_:didSave:contextInfo:)),
                                   contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, didSave: Bool,
                                contextInfo: UnsafeMutableRawPointer?) {
        keepAlive = nil
        completion(didSave)
    }
}

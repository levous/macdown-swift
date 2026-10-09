//
//  DocumentSavingTests.swift
//  MacDownKitTests
//

import AppKit
import Testing
@testable import MacDownKit

/// Stands in for SwiftUI's window delegate.
private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    var askedToClose = 0
    var resized = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        askedToClose += 1
        return true
    }
    func windowDidResize(_ notification: Notification) {
        resized += 1
    }
}

extension LiveDocumentTests {
@MainActor @Suite(.serialized) struct DocumentSavingTests {
    // MARK: Helpers

    func withAutosave<T>(_ on: Bool, _ body: () throws -> T) rethrows -> T {
        let preferences = Preferences.shared
        let saved = preferences.autosavesDocuments
        preferences.autosavesDocuments = on
        defer { preferences.autosavesDocuments = saved }
        return try body()
    }

    /// A controller in a closable window, saving through `saves` (whether
    /// each save succeeds) instead of an NSDocument.
    func makeController(_ text: String = "saved", untitled: Bool = false,
                        fileURL: URL? = nil,
                        saves: @escaping () -> Bool = { true })
        -> (DocumentController, NSWindow) {
        let fileURL = untitled ? nil : fileURL ?? URL(fileURLWithPath: "/tmp/macdown-test.md")
        let controller = DocumentController(document: MarkdownDocument(text: text),
                                            fileURL: fileURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(controller.editorScrollView)
        split.addArrangedSubview(controller.preview.webView)
        // Like SwiftUI's windows: the content view has a view controller.
        let viewController = NSViewController()
        viewController.view = split
        window.contentViewController = viewController
        controller.saveDocument = { _, completion in completion(saves()) }
        controller.viewDidAppear()
        return (controller, window)
    }

    /// Types `text` at the end, as one undoable edit.
    func type(_ text: String, in controller: DocumentController) {
        let editor = controller.editor
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        // One undo group per edit, as AppKit makes one per event.
        controller.undoManager.beginUndoGrouping()
        editor.insertText(text, replacementRange: editor.selectedRange())
        controller.undoManager.endUndoGrouping()
    }

    // MARK: Draft

    @Test func editsStayInTheDraftUntilSaved() {
        withAutosave(false) {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(!controller.hasUnsavedChanges && !window.isDocumentEdited)

            type(" more", in: controller)
            #expect(controller.markdown == "saved more")
            #expect(controller.document.text == "saved")
            #expect(controller.hasUnsavedChanges && window.isDocumentEdited)
            // Typing never touches the window's (SwiftUI's) undo manager, so
            // the document itself doesn't look changed.
            #expect(controller.editor.undoManager === controller.undoManager)
            #expect(window.undoManager?.canUndo != true)

            // Undoing back to the saved text is clean again.
            controller.undoManager.undo()
            #expect(controller.markdown == "saved")
            #expect(!controller.hasUnsavedChanges && !window.isDocumentEdited)
        }
    }

    @Test func untitledDocumentsWithTextAreUnsaved() {
        withAutosave(false) {
            // An empty new window has nothing to lose.
            let (empty, emptyWindow) = makeController("", untitled: true)
            defer { empty.tearDown(); emptyWindow.close() }
            #expect(!empty.hasUnsavedChanges)
            type("new", in: empty)
            #expect(empty.hasUnsavedChanges)

            // A duplicate or piped-in text is untitled with content.
            let (copy, copyWindow) = makeController("copied", untitled: true)
            defer { copy.tearDown(); copyWindow.close() }
            #expect(copy.hasUnsavedChanges && copyWindow.isDocumentEdited)
            // Once saved somewhere, it isn't.
            copy.save()
            copy.fileURL = URL(fileURLWithPath: "/tmp/macdown-copy.md")
            #expect(!copy.hasUnsavedChanges && !copyWindow.isDocumentEdited)
        }
    }

    @Test func savingCommitsTheDraft() {
        withAutosave(false) {
            var succeeds = false
            let (controller, window) = makeController(saves: { succeeds })
            defer { controller.tearDown(); window.close() }
            type(" more", in: controller)

            var result: Bool?
            controller.save { result = $0 }
            // A cancelled save panel or a failed save leaves it unsaved.
            #expect(result == false && controller.hasUnsavedChanges)

            succeeds = true
            controller.save { result = $0 }
            #expect(result == true)
            #expect(controller.document.text == "saved more")
            #expect(!controller.hasUnsavedChanges && !window.isDocumentEdited)
        }
    }

    @Test func autosavingSendsEveryEditToTheDocument() {
        withAutosave(true) {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            type(" more", in: controller)
            #expect(controller.document.text == "saved more")
            #expect(!controller.hasUnsavedChanges)
        }
    }

    @Test func turningAutosavingOnSavesTheDraft() {
        let (controller, window) = makeController()
        defer { controller.tearDown(); window.close() }
        withAutosave(false) {
            type(" more", in: controller)
            #expect(controller.document.text == "saved")
            withAutosave(true) {
                #expect(controller.document.text == "saved more")
                #expect(!controller.hasUnsavedChanges)
            }
        }
    }

    @Test func fileChangesKeepAnUnsavedDraft() {
        withAutosave(false) {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            // No unsaved changes: the new text is loaded.
            controller.replaceDocument(MarkdownDocument(text: "changed on disk"))
            #expect(controller.markdown == "changed on disk")
            #expect(!controller.hasUnsavedChanges)

            // Unsaved changes: the draft is kept, and is still unsaved.
            type(" mine", in: controller)
            controller.replaceDocument(MarkdownDocument(text: "changed again"))
            #expect(controller.markdown == "changed on disk mine")
            #expect(controller.hasUnsavedChanges)
        }
    }

    // MARK: Changes on disk

    /// A file holding `text`, removed when the returned closure is called.
    func makeFile(_ text: String = "saved") throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("file.md")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test func fileChangesLoadWithoutUnsavedChanges() throws {
        try withAutosave(false) {
            let (url, remove) = try makeFile()
            defer { remove() }
            let (controller, window) = makeController(fileURL: url)
            defer { controller.tearDown(); window.close() }
            var asked = 0
            controller.isWindowActive = { _ in true }
            controller.askAboutFileChange = { _, answer in asked += 1; answer(false) }

            try "changed".write(to: url, atomically: true, encoding: .utf8)
            controller.checkFileOnDisk()
            #expect(controller.markdown == "changed")
            #expect(controller.document.text == "changed")
            #expect(!controller.hasUnsavedChanges)
            #expect(asked == 0)
        }
    }

    @Test func fileChangesAskBeforeReplacingUnsavedChanges() throws {
        try withAutosave(false) {
            let (url, remove) = try makeFile()
            defer { remove() }
            let (controller, window) = makeController(fileURL: url)
            defer { controller.tearDown(); window.close() }
            var answer = true
            var asked = 0
            controller.isWindowActive = { _ in true }
            controller.askAboutFileChange = { _, reply in asked += 1; reply(answer) }

            // Revert: the file is loaded.
            type(" mine", in: controller)
            try "changed".write(to: url, atomically: true, encoding: .utf8)
            controller.checkFileOnDisk()
            #expect(asked == 1)
            #expect(controller.markdown == "changed")
            #expect(!controller.hasUnsavedChanges)
            // The undo actions referred to the old text.
            #expect(!controller.undoManager.canUndo)

            // Keep: the draft stays, unsaved relative to the new file, and
            // the same change isn't asked about again.
            answer = false
            type(" mine", in: controller)
            try "changed again".write(to: url, atomically: true, encoding: .utf8)
            controller.checkFileOnDisk()
            #expect(asked == 2)
            #expect(controller.markdown == "changed mine")
            #expect(controller.hasUnsavedChanges)
            #expect(controller.document.text == "changed again")
            controller.checkFileOnDisk()
            #expect(asked == 2)
        }
    }

    @Test func fileChangesWaitForTheWindowToAsk() throws {
        try withAutosave(false) {
            let (url, remove) = try makeFile()
            defer { remove() }
            let (controller, window) = makeController(fileURL: url)
            defer { controller.tearDown(); window.close() }
            var active = false
            var asked = 0
            controller.isWindowActive = { _ in active }
            controller.askAboutFileChange = { _, reply in asked += 1; reply(false) }

            type(" mine", in: controller)
            try "changed".write(to: url, atomically: true, encoding: .utf8)
            controller.checkFileOnDisk()
            #expect(asked == 0)
            #expect(controller.markdown == "saved mine")

            active = true
            controller.checkFileOnDisk()
            #expect(asked == 1)
        }
    }

    @Test func fileChangedToTheDraftIsSaved() throws {
        try withAutosave(false) {
            let (url, remove) = try makeFile()
            defer { remove() }
            let (controller, window) = makeController(fileURL: url)
            defer { controller.tearDown(); window.close() }
            var asked = 0
            controller.isWindowActive = { _ in true }
            controller.askAboutFileChange = { _, reply in asked += 1; reply(false) }

            type(" mine", in: controller)
            try "saved mine".write(to: url, atomically: true, encoding: .utf8)
            controller.checkFileOnDisk()
            #expect(asked == 0)
            #expect(!controller.hasUnsavedChanges)
        }
    }

    @Test func watcherNoticesFileChanges() async throws {
        let autosaved = Preferences.shared.autosavesDocuments
        Preferences.shared.autosavesDocuments = false
        defer { Preferences.shared.autosavesDocuments = autosaved }
        let (url, remove) = try makeFile()
        defer { remove() }
        let (controller, window) = makeController(fileURL: url)
        defer { controller.tearDown(); window.close() }

        func waitFor(_ text: String) async -> Bool {
            for _ in 0..<50 {
                if controller.markdown == text { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        // Written in place, then replaced (an atomic save), then in place
        // again, which needs the watcher to have followed the replacement.
        try "in place".write(to: url, atomically: false, encoding: .utf8)
        #expect(await waitFor("in place"))
        try "replaced".write(to: url, atomically: true, encoding: .utf8)
        #expect(await waitFor("replaced"))
        try "in place again".write(to: url, atomically: false, encoding: .utf8)
        #expect(await waitFor("in place again"))
    }

    // MARK: File ▸ Save (⌘S)

    /// The object a menu action reaches from `first`, the way AppKit finds
    /// it: up the responder chain, asking each responder whether it handles
    /// the action or has a supplemental target for it (SwiftUI's window
    /// answers with its document).
    func target(for action: Selector, from first: NSResponder?) -> AnyObject? {
        var responder = first
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil) {
                return supplemental as AnyObject
            }
            responder = current.nextResponder
        }
        return nil
    }

    @Test func saveDocumentActionSavesTheDraft() throws {
        try withAutosave(false) {
            var saves = 0
            let (controller, window) = makeController(saves: { saves += 1; return true })
            defer { controller.tearDown(); window.close() }
            let save = NSSelectorFromString("saveDocument:")    // What ⌘S sends.
            let responder = try #require(controller.responder)

            // The responder comes right before the window (after the content
            // view's controller, as in SwiftUI's windows), so ahead of
            // anything the window would hand the action to.
            let viewController = try #require(window.contentViewController)
            #expect(viewController.nextResponder === responder)
            #expect(responder.nextResponder === window)

            // ⌘S reaches it from the editor and from the preview.
            #expect(target(for: save, from: controller.editor) === responder)
            #expect(target(for: save, from: controller.preview.webView) === responder)
            // The window starts with the editor focused, not the window.
            #expect(window.firstResponder === controller.editor)

            type(" more", in: controller)
            NSApp.sendAction(save, to: responder, from: nil)
            #expect(saves == 1)
            #expect(controller.document.text == "saved more" && !controller.hasUnsavedChanges)

            // If the chain is rewired, the responder goes back in.
            let other = NSResponder()
            viewController.nextResponder = other
            #expect(viewController.nextResponder === responder && responder.nextResponder === other)

            controller.tearDown()
            #expect(viewController.nextResponder === other)
        }
    }

    @Test func saveAsWritesTheDraftToTheNewFile() {
        withAutosave(false) {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            var written: String?
            var chooses = false    // Whether the save panel is confirmed.
            controller.saveDocumentAs = { controller, completion in
                written = controller.document.text
                completion(chooses)
            }
            type(" more", in: controller)

            // Cancelled: nothing written; the document still holds what's on
            // disk and the draft is still unsaved.
            var result: Bool?
            controller.saveAs { result = $0 }
            #expect(result == false && written == "saved more")
            #expect(controller.document.text == "saved")
            #expect(controller.hasUnsavedChanges && controller.markdown == "saved more")

            // Saved: the new file gets the draft, and it's no longer unsaved.
            chooses = true
            controller.saveAs { result = $0 }
            #expect(result == true && written == "saved more")
            #expect(controller.document.text == "saved more" && !controller.hasUnsavedChanges)
        }
    }

    @Test func duplicateCopiesTheDraft() {
        withAutosave(false) {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            var copied: String?
            controller.duplicateDocument = { copied = $0.document.text }
            type(" more", in: controller)

            controller.duplicate()
            #expect(copied == "saved more")
            // This window keeps its draft, still unsaved, and its file.
            #expect(controller.document.text == "saved")
            #expect(controller.hasUnsavedChanges && controller.markdown == "saved more")
        }
    }

    @Test func saveAsAndDuplicateReachTheResponder() throws {
        let (controller, window) = makeController()
        defer { controller.tearDown(); window.close() }
        let responder = try #require(controller.responder)
        for action in ["saveDocumentAs:", "duplicateDocument:"] {
            #expect(target(for: NSSelectorFromString(action), from: controller.editor) === responder)
        }
    }

    // MARK: Closing

    @Test func closeGuardForwardsToTheOriginalDelegate() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = RecordingWindowDelegate()
        window.delegate = original
        let closeGuard = WindowCloseGuard(shouldClose: { _ in false })
        closeGuard.install(on: window)
        #expect(window.delegate === closeGuard && closeGuard.original === original)

        // Other delegate messages reach the original.
        window.setContentSize(NSSize(width: 300, height: 300))
        #expect(original.resized > 0)
        // The guard answers windowShouldClose first.
        #expect(closeGuard.windowShouldClose(window) == false)
        #expect(original.askedToClose == 0)

        // If the delegate is replaced, the guard wraps the new one.
        let replacement = RecordingWindowDelegate()
        window.delegate = replacement
        #expect(window.delegate === closeGuard && closeGuard.original === replacement)

        closeGuard.uninstall(from: window)
        #expect(window.delegate === replacement)
    }

    @Test func closingAsksAboutUnsavedChanges() async throws {
        let saved = DocumentSaving.askBeforeClosing
        defer { DocumentSaving.askBeforeClosing = saved }
        @MainActor func close(answering choice: DocumentSaving.UnsavedChangesChoice?,
                   edit: Bool = true, saves: Bool = true) async throws
            -> (asked: Int, closed: Bool, unsaved: Bool) {
            nonisolated(unsafe) var asked = 0
            DocumentSaving.askBeforeClosing = { _, _, reply in
                asked += 1
                reply(choice ?? .cancel)
            }
            let (controller, window) = makeController(saves: { saves })
            defer { controller.tearDown(); window.close() }
            window.orderFront(nil)
            if edit { type(" more", in: controller) }
            // Click the close button: AppKit asks the delegate, then closes.
            // (performClose(_:) itself runs a nested event loop that stops a
            // test runner's main run loop.)
            controller.closeGuard?.closeWindow = { window in
                if window.delegate?.windowShouldClose?(window) ?? true { window.close() }
            }
            if window.delegate?.windowShouldClose?(window) ?? true { window.close() }
            // Closing after an answer waits for the current event to finish.
            try await Task.sleep(for: .milliseconds(100))
            return (asked, !window.isVisible, controller.hasUnsavedChanges)
        }
        let preferences = Preferences.shared
        let autosaved = preferences.autosavesDocuments
        preferences.autosavesDocuments = false
        defer { preferences.autosavesDocuments = autosaved }
        #expect(try await close(answering: .cancel) == (1, false, true))
        #expect(try await close(answering: .discard) == (1, true, false))
        #expect(try await close(answering: .save) == (1, true, false))
        #expect(try await close(answering: .save, saves: false) == (1, false, true))
        // Nothing unsaved: closes without asking.
        #expect(try await close(answering: nil, edit: false) == (0, true, false))
    }

    // MARK: Quitting

    @Test func quittingAsksAboutUnsavedDrafts() {
        let saved = DocumentSaving.askBeforeQuitting
        defer { DocumentSaving.askBeforeQuitting = saved }
        withAutosave(false) {
            var order: [Int] = []
            var succeeds = [true, true, true]
            let pairs = (0..<3).map { index in
                makeController(saves: { order.append(index); return succeeds[index] })
            }
            defer { pairs.forEach { $0.0.tearDown(); $0.1.close() } }
            let controllers = pairs.map(\.0)
            @MainActor func review(_ choice: DocumentSaving.UnsavedChangesChoice) -> (asked: Bool, quit: Bool?) {
                DocumentSaving.askBeforeQuitting = { _ in choice }
                var quit: Bool?
                let asked = DocumentSaving.reviewBeforeQuitting(controllers) { quit = $0 }
                return (asked, quit)
            }

            // Nothing unsaved: nothing to ask.
            #expect(review(.save) == (false, nil))

            controllers.forEach { type(" more", in: $0) }
            #expect(review(.cancel) == (true, false))
            #expect(controllers.allSatisfy { $0.hasUnsavedChanges })

            // A failed save stops saving and cancels quitting.
            succeeds[1] = false
            #expect(review(.save) == (true, false))
            #expect(order == [0, 1])
            #expect(controllers.map(\.hasUnsavedChanges) == [false, true, true])

            succeeds[1] = true
            order = []
            #expect(review(.save) == (true, true))
            #expect(order == [1, 2])
            #expect(controllers.allSatisfy { !$0.hasUnsavedChanges })

            controllers.forEach { type(" again", in: $0) }
            #expect(review(.discard) == (true, true))
            #expect(controllers.allSatisfy { !$0.hasUnsavedChanges })
            #expect(controllers.allSatisfy { $0.document.text == "saved more" })
        }
    }

    // MARK: The alert

    @Test func theAlertOffersSaveDiscardAndCancel() {
        let alert = DocumentSaving.makeAlert(saveTitle: "Save", names: ["notes.md"])
        #expect(alert.messageText == "You have unsaved changes.")
        #expect(alert.informativeText == "notes.md")
        #expect(alert.buttons.map(\.title) == ["Save", "Discard", "Cancel"])
        // Discard is red, Return saves and Escape cancels.
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, true, false])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[2].keyEquivalent == "\u{1b}")
        #expect(DocumentSaving.choice(for: .alertFirstButtonReturn) == .save)
        #expect(DocumentSaving.choice(for: .alertSecondButtonReturn) == .discard)
        #expect(DocumentSaving.choice(for: .alertThirdButtonReturn) == .cancel)
    }
}
}

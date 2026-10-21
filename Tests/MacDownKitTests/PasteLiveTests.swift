//
//  PasteLiveTests.swift
//  MacDownKitTests
//
//  Paste, Paste and Match Style and Paste as Markdown in a real document
//  (paste intent, FR-1 to FR-9, FR-28, FR-33, FR-34). These use the general
//  pasteboard, as the menu actions do, and put back what was on it.
//

import AppKit
import Testing
@testable import MacDownKit

extension LiveDocumentTests {
@MainActor @Suite(.serialized) struct PasteLiveTests {
    /// A document saved at a file, so only edits count as unsaved, with
    /// "Save changes automatically" off and conversion on.
    func withDocument(_ text: String, _ body: (DocumentController) async throws -> Void) async rethrows {
        let preferences = Preferences.shared
        let saved = (preferences.autosavesDocuments, preferences.editorConvertsPastedFormatting)
        defer { (preferences.autosavesDocuments, preferences.editorConvertsPastedFormatting) = saved }
        preferences.autosavesDocuments = false
        preferences.editorConvertsPastedFormatting = true

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        let controller = DocumentController(document: MarkdownDocument(text: text), fileURL: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.editorScrollView
        controller.viewDidAppear()
        defer { controller.tearDown(); window.close() }
        controller.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        try await body(controller)
    }

    /// Runs `body` with `types` on the general pasteboard, then puts back
    /// what was there.
    func withClipboard(_ types: [NSPasteboard.PasteboardType: Data], _ body: () async throws -> Void) async rethrows {
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            general.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { general.writeObjects(items) }
        }
        general.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        general.writeObjects([item])
        try await body()
    }

    static let bold: [NSPasteboard.PasteboardType: Data] = [.html: Data("<b>bold</b> text".utf8),
                                                             .string: Data("bold text".utf8)]

    /// A paste after typing is undone on its own, and marks the document
    /// changed (FR-7, FR-9).
    @Test func pasteIsItsOwnUndoStep() async {
        await withDocument("Intro ") { controller in
            let editor = controller.editor
            #expect(!controller.hasUnsavedChanges)
            // Typing and pasting are separate events: let the run loop end
            // the undo group in between, as it does in the app.
            editor.insertText("typed ", replacementRange: editor.selectedRange())
            await Self.nextEvent()
            await withClipboard(Self.bold) { editor.paste(nil) }
            await Self.nextEvent()
            #expect(editor.string == "Intro typed **bold** text")
            #expect(controller.hasUnsavedChanges)
            controller.undoManager.undo()
            #expect(editor.string == "Intro typed ")
            controller.undoManager.undo()
            #expect(editor.string == "Intro ")
        }
    }

    static func nextEvent() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Paste and Match Style pastes the plain text (FR-4).
    @Test func pasteAndMatchStyleIsPlain() async {
        await withDocument("") { controller in
            await withClipboard(Self.bold) { controller.editor.pasteAsPlainText(nil) }
            #expect(controller.editor.string == "bold text")
        }
    }

    /// Inside a code block, Paste pastes the plain text (FR-5).
    @Test func pasteInCodeBlockIsPlain() async {
        await withDocument("```\n") { controller in
            await withClipboard(Self.bold) { controller.editor.paste(nil) }
            #expect(controller.editor.string == "```\nbold text")
        }
    }

    /// With the setting off, Paste is plain and Paste as Markdown converts
    /// (FR-27, FR-28).
    @Test func settingOff() async {
        await withDocument("") { controller in
            Preferences.shared.editorConvertsPastedFormatting = false
            await withClipboard(Self.bold) {
                controller.editor.paste(nil)
                controller.editor.insertText(" / ", replacementRange: controller.editor.selectedRange())
                controller.editor.pasteAsMarkdown(nil)
            }
            #expect(controller.editor.string == "bold text / **bold** text")
        }
    }

    /// Image data is pasted as a data URI, whatever the setting; TIFF as
    /// PNG (FR-33, FR-34).
    @Test(arguments: [true, false])
    func images(converts: Bool) async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let jpeg = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        for (type, mime) in [(NSPasteboard.PasteboardType.png, "image/png"), (.init("public.jpeg"), "image/jpeg"),
                             (.tiff, "image/png")] {
            let data = type == .png ? png : type == .tiff ? tiff : jpeg
            await withDocument("") { controller in
                Preferences.shared.editorConvertsPastedFormatting = converts
                await withClipboard([type: data]) {
                    // Paste is enabled for image data alone.
                    let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
                    #expect(controller.editor.validateMenuItem(item), "\(type.rawValue)")
                    controller.editor.paste(nil)
                }
                #expect(controller.editor.string.hasPrefix("![](data:\(mime);base64,"), "\(type.rawValue)")
                if type != .tiff {
                    #expect(controller.editor.string == "![](data:\(mime);base64,\(data.base64EncodedString()))")
                }
            }
        }
    }
}
}

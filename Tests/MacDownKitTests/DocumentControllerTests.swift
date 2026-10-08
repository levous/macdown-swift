//
//  DocumentControllerTests.swift
//  MacDown
//
//  Integration tests driving a real editor and WKWebView preview.
//

import AppKit
import Testing
@testable import MacDownKit

@MainActor
@Suite(.serialized) struct DocumentControllerTests {
    func makeController(_ text: String) -> (DocumentController, NSWindow) {
        let controller = DocumentController(document: MarkdownDocument(text: text),
                                            fileURL: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(controller.editorScrollView)
        split.addArrangedSubview(controller.preview.webView)
        window.contentView = split
        controller.viewDidAppear()
        return (controller, window)
    }

    func waitUntil(timeout: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func previewHeading(_ controller: DocumentController) async -> String? {
        try? await controller.preview.webView.evaluateJavaScript(
            "document.querySelector('h1') && document.querySelector('h1').textContent"
        ) as? String
    }

    @Test func rendersAndUpdatesPreview() async {
        let (controller, window) = makeController("# First\n")
        defer { controller.tearDown(); window.close() }

        #expect(await waitUntil { await previewHeading(controller) == "First" })

        controller.markdown = "# Second\n"
        #expect(await waitUntil { await previewHeading(controller) == "Second" })
        #expect(controller.document.text == "# Second\n")
        #expect(controller.html.contains("<h1 id=\"toc_0\">Second</h1>"))
    }

    @Test func togglesPanes() {
        let (controller, window) = makeController("text")
        defer { controller.tearDown(); window.close() }

        controller.editorFraction = 0.5
        controller.togglePreviewPane()
        #expect(!controller.previewVisible)
        #expect(controller.editorVisible)
        controller.togglePreviewPane()
        #expect(controller.editorFraction == 0.5)

        controller.toggleEditorPane()
        #expect(!controller.editorVisible)
        #expect(!controller.editor.isEditable)
        controller.toggleEditorPane()
        #expect(controller.editorVisible)
        #expect(controller.editor.isEditable)

        controller.setLeftPaneFraction(0.25)
        #expect(controller.editorFraction == (controller.editorOnRight ? 0.75 : 0.25))
    }

    @Test func presumedFileNameFromHeading() {
        let (controller, window) = makeController("Intro\n\n## A/B: Test\n")
        defer { controller.tearDown(); window.close() }
        #expect(controller.presumedFileName == "A-B- Test")
    }

    @Test func formattingActions() {
        let (controller, window) = makeController("word")
        defer { controller.tearDown(); window.close() }
        controller.editor.setSelectedRange(NSRange(location: 0, length: 4))
        controller.toggleStrong()
        #expect(controller.editor.string == "**word**")
        controller.convertToHeader(level: 3)
        #expect(controller.editor.string == "### **word**")
        controller.toggleUnorderedList()
        #expect(controller.editor.string.hasSuffix("### **word**"))
    }

    @Test func wordCountTitlesAreLocalized() {
        let (controller, window) = makeController("one two")
        defer { controller.tearDown(); window.close() }
        controller.textCount = TextCount(words: 1, characters: 2, charactersNoSpaces: 3)
        #expect(controller.wordCountTitle(for: .words) == "1 word")
        #expect(controller.wordCountTitle(for: .characters) == "2 characters")
        #expect(controller.wordCountTitle(for: .charactersNoSpaces)
                == "3 characters (no spaces)")
    }

    @Test func exportsPDF() async throws {
        let (controller, window) = makeController("# PDF\n\nSome text.\n")
        defer { controller.tearDown(); window.close() }
        #expect(await waitUntil { await previewHeading(controller) == "PDF" })

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdown-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = controller.preview.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Like the app: run asynchronously so WebKit can deliver content.
        window.orderFront(nil)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        #expect(await waitUntil(timeout: 20) {
            ((try? Data(contentsOf: url))?.count ?? 0) > 1000
        })

        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF".utf8)))
        #expect(data.count > 1000)
    }
}

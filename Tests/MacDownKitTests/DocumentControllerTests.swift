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

    // MARK: In-place updates

    func evaluate(_ controller: DocumentController, _ script: String) async -> Any? {
        try? await controller.preview.webView.evaluateJavaScript(script)
    }

    @Test func editsUpdateBodyInPlaceKeepingScroll() async throws {
        let preferences = Preferences.shared
        let saved = (preferences.editorSyncScrolling, preferences.htmlSyntaxHighlighting)
        preferences.editorSyncScrolling = false
        preferences.htmlSyntaxHighlighting = true
        defer {
            preferences.editorSyncScrolling = saved.0
            preferences.htmlSyntaxHighlighting = saved.1
        }
        let filler = (1...80).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let text = "# First\n\n```swift\nlet a = 1\n```\n\n\(filler)\n"
        let (controller, window) = makeController(text)
        defer { controller.tearDown(); window.close() }
        #expect(await waitUntil { await previewHeading(controller) == "First" })

        _ = await evaluate(controller, "window.scrollTo(0, 1000); window.macdownMarker = 1; 0")
        controller.markdown = text.replacingOccurrences(of: "# First", with: "# Second")
            + "\n```swift\nlet b = 2\n```\n"
        #expect(await waitUntil { await previewHeading(controller) == "Second" })
        #expect(await waitUntil { !controller.preview.isLoading })

        // Same page (not reloaded), same scroll position, code highlighted.
        #expect(await evaluate(controller, "window.macdownMarker") as? Int == 1)
        #expect(await evaluate(controller, "window.scrollY") as? Int == 1000)
        #expect(await evaluate(controller,
            "document.querySelectorAll('pre code').length") as? Int == 2)
        #expect(await evaluate(controller,
            "document.querySelectorAll('pre code .token').length > 2") as? Bool == true)
    }

    @Test func pageChangesReloadThePage() async throws {
        let (controller, window) = makeController("# First\n")
        defer { controller.tearDown(); window.close() }
        #expect(await waitUntil { await previewHeading(controller) == "First" })
        _ = await evaluate(controller, "window.macdownMarker = 1; 0")

        // A different stylesheet can't be swapped in by replacing the body.
        var settings = Preferences.shared.renderSettings.page
        settings.styleName = settings.styleName == "GitHub2" ? "Clearness" : "GitHub2"
        let html = PageBuilder.previewHTML(
            title: "", result: ParseResult(body: "<h1>Reloaded</h1>", languages: []),
            settings: settings, linkTransform: PreviewURL.previewURL(for:))
        controller.preview.load(html: html, baseURL: controller.preview.currentBaseURL,
                                waitForMathJax: false, restoresScroll: false)
        #expect(await waitUntil { await previewHeading(controller) == "Reloaded" })
        #expect(await evaluate(controller, "window.macdownMarker") == nil)
    }

    @Test func fallsBackToReloadWithoutMarkers() async throws {
        let (controller, window) = makeController("# First\n")
        defer { controller.tearDown(); window.close() }
        #expect(await waitUntil { await previewHeading(controller) == "First" })
        // E.g. the web content process restarted with a blank page.
        _ = await evaluate(controller, "document.body.innerHTML = ''; 0")
        controller.markdown = "# Second\n"
        #expect(await waitUntil { await previewHeading(controller) == "Second" })
    }

    @Test func editsKeepSyncedPreviewPosition() async throws {
        let preferences = Preferences.shared
        let saved = preferences.editorSyncScrolling
        preferences.editorSyncScrolling = true
        defer { preferences.editorSyncScrolling = saved }
        let sections = (1...12).map {
            "## Section \($0)\n\n" + (1...6).map { "Paragraph \($0)." }
                .joined(separator: "\n\n")
        }
        let text = "# First\n\n" + sections.joined(separator: "\n\n") + "\n"
        let (controller, window) = makeController(text)
        defer { controller.tearDown(); window.close() }
        #expect(await waitUntil { await previewHeading(controller) == "First" })
        #expect(await waitUntil { !controller.preview.isLoading })

        // Scroll the editor to the middle; the preview follows.
        let clipView = controller.editorScrollView.contentView
        let middle = (controller.editorScrollView.documentView!.bounds.height
                      - clipView.bounds.height) / 2
        clipView.scroll(to: NSPoint(x: 0, y: middle))
        controller.editorScrollView.reflectScrolledClipView(clipView)
        var synced: Double = 0
        #expect(await waitUntil {
            synced = await evaluate(controller, "window.scrollY") as? Double ?? 0
            return synced > 0
        })
        _ = await evaluate(controller, "window.macdownMarker = 1; 0")
        // Type in the middle of the visible text, like a user would.
        let visible = clipView.bounds
        let editor = controller.editor
        let origin = editor.textContainerOrigin
        let glyph = editor.layoutManager!.glyphIndex(
            for: NSPoint(x: 0, y: visible.midY - origin.y), in: editor.textContainer!)
        let index = editor.layoutManager!.characterIndexForGlyph(at: glyph)
        // Inside a paragraph, so no header or anchor changes.
        let word = (editor.string as NSString).range(
            of: "Paragraph", range: NSRange(location: index,
                                            length: (editor.string as NSString).length - index))
        editor.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
        editor.insertText(" Typed", replacementRange: editor.selectedRange())
        #expect(clipView.bounds.minY == visible.minY)
        #expect(await waitUntil {
            await evaluate(controller,
                "document.body.textContent.indexOf('Paragraph Typed') >= 0") as? Bool == true
        })
        #expect(await waitUntil { !controller.preview.isLoading })
        try await Task.sleep(for: .milliseconds(300))

        // Updated in place, never jumping to the top. (Typing may rewrap a
        // line in either pane, so allow a line's difference.)
        #expect(await evaluate(controller, "window.macdownMarker") as? Int == 1)
        let y = await evaluate(controller, "window.scrollY") as? Double ?? 0
        #expect(abs(y - synced) < 25, "\(y) vs \(synced)")
    }
}

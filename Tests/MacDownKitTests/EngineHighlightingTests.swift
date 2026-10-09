//
//  EngineHighlightingTests.swift
//  MacDownKitTests
//
//  With the swift-markdown engine, the editor is highlighted from the
//  renderer's document model instead of its own PEG parse (FR-1, FR-26).
//

import AppKit
import Testing
@testable import MacDownKit

extension LiveDocumentTests {
@MainActor @Suite(.serialized) struct EngineHighlightingTests {
    func makeController(_ text: String) -> (DocumentController, NSWindow) {
        let controller = DocumentController(document: MarkdownDocument(text: text), fileURL: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(controller.editorScrollView)
        split.addArrangedSubview(controller.preview.webView)
        window.contentView = split
        controller.viewDidAppear()
        return (controller, window)
    }

    func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func color(_ controller: DocumentController, at needle: String) -> NSColor? {
        let location = (controller.editor.string as NSString).range(of: needle).location
        return controller.editor.textStorage?.attribute(.foregroundColor, at: location,
                                                        effectiveRange: nil) as? NSColor
    }

    /// `#Not a header` isn't one in CommonMark, but PEG colored it; both
    /// color a real header.
    @Test(arguments: [MarkdownEngine.hoedown, .swiftMarkdown])
    func highlightsFromTheEngine(_ engine: MarkdownEngine) async {
        let preferences = Preferences.shared
        let saved = preferences.markdownEngine
        preferences.markdownEngine = engine
        defer { preferences.markdownEngine = saved }

        let (controller, window) = makeController("Plain text.\n\n## Real\n\n#Not a header\n")
        defer { controller.tearDown(); window.close() }
        #expect(controller.highlighter.usesExternalElements == (engine == .swiftMarkdown))
        #expect(await waitUntil { color(controller, at: "Real") != color(controller, at: "Plain") })
        let notHeader = color(controller, at: "Not a header") != color(controller, at: "Plain")
        #expect(notHeader == (engine == .hoedown))
    }

    /// Edits re-highlight from the new model, also with the preview's
    /// automatic updates off (no render, so a parse just for highlighting).
    @Test(arguments: [false, true])
    func editsRehighlight(manualRender: Bool) async {
        let preferences = Preferences.shared
        let saved = (preferences.markdownEngine, preferences.markdownManualRender)
        preferences.markdownEngine = .swiftMarkdown
        preferences.markdownManualRender = manualRender
        defer { (preferences.markdownEngine, preferences.markdownManualRender) = saved }

        let (controller, window) = makeController("Plain text.\n")
        defer { controller.tearDown(); window.close() }
        let plain = color(controller, at: "Plain")
        controller.editor.insertText("\n\n> ## Added\n", replacementRange:
            NSRange(location: (controller.editor.string as NSString).length, length: 0))
        #expect(await waitUntil {
            controller.editor.string.contains("Added") && color(controller, at: "Added") != plain
        })
    }
}
}

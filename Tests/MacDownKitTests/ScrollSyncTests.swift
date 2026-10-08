//
//  ScrollSyncTests.swift
//  MacDownKitTests
//

import AppKit
import Testing
@testable import MacDownKit

@Suite struct ScrollAnchorsTests {
    func kinds(_ markdown: String, frontMatter: Bool = false) -> [String] {
        let ns = markdown as NSString
        return ScrollAnchors.scan(markdown, skipsFrontMatter: frontMatter).map {
            ($0.kind == .header ? "h:" : "i:") + ns.substring(with: $0.range)
        }
    }

    @Test func headers() {
        #expect(kinds("# One\ntext\n\n##Two\n") == ["h:# One", "h:##Two"])
        #expect(kinds("Title\n=====\n\nSub\n---  \n") == ["h:Title\n=====", "h:Sub\n---  "])
        // A rule under an ATX header, list or blank line is not a header.
        #expect(kinds("# One\n---\n") == ["h:# One"])
        #expect(kinds("- item\n---\n") == [])
        #expect(kinds("\n---\n") == [])
    }

    @Test func skipsCodeCommentsAndFrontMatter() {
        #expect(kinds("```sh\n# comment\n![a](b)\n```\n# Real\n") == ["h:# Real"])
        #expect(kinds("~~~~\n```\n# no\n~~~~\n") == [])
    }

    @Test func fencesFollowHoedown() {
        // A line that repeats the fence characters is a code span.
        #expect(kinds("```` ``a`` ````\n\n# H\n") == ["h:# H"])
        // Only the same width (and indent) closes a fence.
        #expect(kinds("````\n```\n# no\n````\n# yes\n") == ["h:# yes"])
        #expect(kinds("```\n# no\n  ```\n# no\n```\n# yes\n") == ["h:# yes"])
        // Fences don't interrupt paragraphs.
        #expect(kinds("text\n```\n# H\n") == ["h:# H"])
        #expect(ScrollAnchors.scan("```\n# H\n```\n", skipsFrontMatter: false,
                                   fencedCode: false).count == 1)
        #expect(kinds("<!--\n# hidden\n-->\n# Shown\n") == ["h:# Shown"])
        #expect(kinds("---\ntitle: x\n---\n# A\n", frontMatter: true) == ["h:# A"])
        #expect(kinds("---\ntitle: x\n---\n# A\n", frontMatter: false)
                == ["h:title: x\n---", "h:# A"])
    }

    @Test func imagesInImageOnlyParagraphs() {
        #expect(kinds("![a](1)\n") == ["i:![a](1)"])
        // Consecutive lines make one paragraph; every image is an anchor.
        #expect(kinds("![a](1)\n![b](2) ![c][r]\n")
                == ["i:![a](1)", "i:![b](2)", "i:![c][r]"])
        // Not stand-alone: text, links, lists, quotes, indented code.
        #expect(kinds("Text ![a](1)\n") == [])
        #expect(kinds("Text\n![a](1)\n") == [])
        #expect(kinds("[![a](1)](http://x)\n") == [])
        #expect(kinds("- ![a](1)\n") == [])
        #expect(kinds("> ![a](1)\n") == [])
        #expect(kinds("    ![a](1)\n") == [])
    }
}

@Suite struct ScrollMapTests {
    let editor = ScrollGeometry(contentHeight: 1000, visibleHeight: 200)
    let preview = ScrollGeometry(contentHeight: 3000, visibleHeight: 400)

    @Test func focusTapersToEdges() {
        #expect(editor.focus(at: 0) == 0)
        #expect(editor.focus(at: 800) == 1000)
        #expect(editor.focus(at: 400) == 500)    // Middle of the view.
        for y in stride(from: CGFloat(0), through: 800, by: 25) {
            #expect(abs(editor.offset(forFocus: editor.focus(at: y)) - y) < 0.01)
        }
    }

    @Test func alignsAnchorsAtCenterInBothDirections() {
        let map = ScrollMap(editor: [ScrollAnchor(.header, 300), ScrollAnchor(.image, 500)],
                            preview: [ScrollAnchor(.header, 700), ScrollAnchor(.image, 1800)],
                            editorEnd: 1000, previewEnd: 3000)
        // Image anchor centered in the editor → centered in the preview.
        let y = map.previewOffset(forEditorOffset: 400, editor: editor, preview: preview)
        #expect(abs(y - (1800 - 200)) < 0.01)
        let back = map.editorOffset(forPreviewOffset: 1600, editor: editor, preview: preview)
        #expect(abs(back - 400) < 0.01)
        // Ends meet.
        #expect(map.previewOffset(forEditorOffset: 0, editor: editor, preview: preview) == 0)
        #expect(map.previewOffset(forEditorOffset: 800, editor: editor, preview: preview)
                == preview.maxOffset)
    }

    @Test func mismatchedAnchorsFallBack() {
        // Image anchors disagree; headers still pair up.
        let map = ScrollMap(editor: [ScrollAnchor(.image, 100), ScrollAnchor(.header, 300)],
                            preview: [ScrollAnchor(.header, 900)],
                            editorEnd: 1000, previewEnd: 3000)
        #expect(map.pairs.map(\.editor) == [0, 300, 1000])
        #expect(map.pairs.map(\.preview) == [0, 900, 3000])
    }
}

/// Drives a real editor and preview, at unequal widths.
@MainActor @Suite(.serialized) struct ScrollSyncIntegrationTests {
    static let image = "![tall](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0MDAiIGhlaWdodD0iNjAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjYwMCIgZmlsbD0iIzg4OCIvPjwvc3ZnPg==)"

    static var markdown: String {
        let filler = (1...6).map { "Paragraph \($0) with some words in it." }
            .joined(separator: "\n\n")
        return """
            # Title
            ---
            \(filler)

            \(image)

            \(image)
            \(image)

            Text \(image) inline.

            [\(image)](http://example.com)

            - \(image)

            > \(image)

            ```sh
            # comment
            \(image)
            ```

            Setext
            ======

            \(filler)

            #NoSpace

            <!--
            # hidden
            -->

            \(image)

            \(filler)

            ## Middle

            \(filler)

            \(image)

            \(filler)

            ## End

            \(filler)
            """
    }

    func makeController(_ text: String = Self.markdown) -> (DocumentController, NSWindow) {
        let controller = DocumentController(document: MarkdownDocument(text: text),
                                            fileURL: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(controller.editorScrollView)
        split.addArrangedSubview(controller.preview.webView)
        window.contentView = split
        split.adjustSubviews()
        split.setPosition(300, ofDividerAt: 0)    // Narrow editor, wide preview.
        controller.viewDidAppear()
        return (controller, window)
    }

    func waitUntil(timeout: Double = 10,
                   _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func previewScrollY(_ controller: DocumentController) async -> CGFloat {
        CGFloat((try? await controller.preview.webView.evaluateJavaScript(
            "window.scrollY") as? NSNumber)?.doubleValue ?? -1)
    }

    func withSyncScrolling(_ body: () async throws -> Void) async rethrows {
        let preferences = Preferences.shared
        let saved = (preferences.editorSyncScrolling, preferences.htmlStyleName)
        preferences.editorSyncScrolling = true
        preferences.htmlStyleName = "GitHub2"
        defer {
            preferences.editorSyncScrolling = saved.0
            preferences.htmlStyleName = saved.1
        }
        try await body()
    }

    @Test func anchorsMatchAndAlignAtCenter() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }

            let ok1 = await waitUntil { controller.previewMetrics.anchors.count > 0 }


            #expect(ok1)
            let kinds: (ScrollAnchorKind) -> String = { $0 == .header ? "h" : "i" }
            let editorKinds = controller.editorAnchors.map { kinds($0.kind) }
            let previewKinds = controller.previewMetrics.anchors.map { kinds($0.kind) }
            #expect(editorKinds == ["h", "i", "i", "i", "h", "h", "i", "h", "i", "h"])
            #expect(previewKinds == editorKinds)

            // Put an image in the middle of the editor (away from the first
            // and last screens, where alignment tapers to the edges).
            let editorAnchor = controller.editorAnchors[6].position
            let previewAnchor = controller.previewMetrics.anchors[6].position
            let editorHeight = controller.editorScrollView.contentView.bounds.height
            let previewHeight = controller.previewMetrics.visibleHeight
            let clipView = controller.editorScrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: editorAnchor - editorHeight / 2))
            controller.editorScrollView.reflectScrolledClipView(clipView)

            // The preview follows, with the same image in its middle.
            let expected = previewAnchor - previewHeight / 2
            let ok2 = await waitUntil {
                abs(await previewScrollY(controller) - expected) < 2
            }

            #expect(ok2)

            // Scrolling the preview moves the editor the same way.
            try await Task.sleep(for: .milliseconds(400))
            let previewAnchor2 = controller.previewMetrics.anchors[4].position
            let editorAnchor2 = controller.editorAnchors[4].position
            let previewY = previewAnchor2 - previewHeight / 2
            _ = try await controller.preview.webView.evaluateJavaScript(
                "window.scrollTo(0, \(previewY)); 0")
            // The page reports scrolling from animation frames, which WebKit
            // doesn't run in test windows that aren't on screen.
            controller.preview.pageDidScroll(to: previewY)
            let ok3 = await waitUntil {
                abs(clipView.bounds.minY - (editorAnchor2 - editorHeight / 2)) < 2
            }

            #expect(ok3)
        }
    }

    @Test func resizingKeepsAlignment() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            let ok4 = await waitUntil { controller.previewMetrics.anchors.count > 0 }

            #expect(ok4)
            let before = controller.previewMetrics.contentHeight

            // A narrower preview scales the images down and rewraps text.
            (window.contentView as! NSSplitView).setPosition(600, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(200))
            controller.preview.pageLayoutDidChange()    // See above.
            let ok5 = await waitUntil {
                controller.previewMetrics.contentHeight != before
            }

            #expect(ok5)
            // The page reports again when the scaled images settle (the
            // resize observer); do the same once things are quiet.
            try await Task.sleep(for: .milliseconds(300))
            controller.preview.pageLayoutDidChange()
            try await Task.sleep(for: .milliseconds(300))
            let editorHeight = controller.editorScrollView.contentView.bounds.height
            let previewHeight = controller.previewMetrics.visibleHeight
            let clipView = controller.editorScrollView.contentView
            clipView.scroll(to: NSPoint(
                x: 0, y: controller.editorAnchors[4].position - editorHeight / 2))
            controller.editorScrollView.reflectScrolledClipView(clipView)
            let expected = controller.previewMetrics.anchors[4].position - previewHeight / 2
            let ok6 = await waitUntil {
                abs(await previewScrollY(controller) - expected) < 2
            }

            #expect(ok6)
        }
    }

    @Test func reporterScriptRuns() async throws {
        let (controller, window) = makeController()
        defer { controller.tearDown(); window.close() }
        let ok = await waitUntil { controller.previewMetrics.anchors.count > 0 }
        #expect(ok)
        // Animation frames don't run here, but setting up the listeners does,
        // and throws on any error.
        let result = try await controller.preview.webView.evaluateJavaScript(
            PreviewController.scrollReporterScript + "; 'ok'")
        #expect(result as? String == "ok")
    }

    @Test func rerenderKeepsPositionWhenPreviewLeads() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            let ok1 = await waitUntil { controller.previewMetrics.anchors.count > 0 }
            #expect(ok1)
            let previewHeight = controller.previewMetrics.visibleHeight
            let previewY = controller.previewMetrics.anchors[6].position - previewHeight / 2
            // Past the window in which scrolling is attributed to the sync.
            try await Task.sleep(for: .milliseconds(400))
            _ = try await controller.preview.webView.evaluateJavaScript(
                "window.scrollTo(0, \(previewY)); 0")
            controller.preview.pageDidScroll(to: previewY)
            let clipView = controller.editorScrollView.contentView
            let editorY = clipView.bounds.minY
            #expect(editorY > 0)

            // Re-rendering without typing (e.g. a theme change) keeps both.
            controller.render()
            let ok2 = await waitUntil {
                abs(await previewScrollY(controller) - previewY) < 2
            }
            #expect(ok2)
            #expect(abs(clipView.bounds.minY - editorY) < 2)
        }
    }

    /// The bundled help, a long document that exercises most of Markdown.
    @Test func helpDocumentAnchorsMatch() async throws {
        try await withSyncScrolling {
        let url = try #require(MPPaths.resourceBundle.url(forResource: "help",
                                                          withExtension: "md"))
        let (controller, window) = makeController(try String(contentsOf: url, encoding: .utf8))
        defer { controller.tearDown(); window.close() }
        let ok = await waitUntil { controller.previewMetrics.anchors.count > 0 }
        #expect(ok)
        // Without sync scrolling, metrics aren't fetched; fetch them here.
        let preview = await controller.preview.fetchMetrics().anchors.map(\.kind)
        controller.updateEditorAnchors()
        #expect(controller.editorAnchors.count > 30)
        #expect(controller.editorAnchors.map(\.kind) == preview)
        }
    }
}

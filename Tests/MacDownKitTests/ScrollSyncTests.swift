//
//  ScrollSyncTests.swift
//  MacDownKitTests
//

import AppKit
import Testing
@testable import MacDownKit

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
        let map = ScrollMap(editor: [ScrollAnchor(line: 3, 300), ScrollAnchor(line: 5, 500)],
                            preview: [ScrollAnchor(line: 3, 700), ScrollAnchor(line: 5, 1800)],
                            editorEnd: 1000, previewEnd: 3000)
        // Line 5 centered in the editor → centered in the preview.
        let y = map.previewOffset(forEditorOffset: 400, editor: editor, preview: preview)
        #expect(abs(y - (1800 - 200)) < 0.01)
        let back = map.editorOffset(forPreviewOffset: 1600, editor: editor, preview: preview)
        #expect(abs(back - 400) < 0.01)
        // Ends meet.
        #expect(map.previewOffset(forEditorOffset: 0, editor: editor, preview: preview) == 0)
        #expect(map.previewOffset(forEditorOffset: 800, editor: editor, preview: preview)
                == preview.maxOffset)
    }

    /// Anchors pair by line number; lines one side lacks are skipped.
    @Test func linesPairByNumber() {
        let map = ScrollMap(editor: [ScrollAnchor(line: 1, 0), ScrollAnchor(line: 5, 200),
                                     ScrollAnchor(line: 9, 400)],
                            preview: [ScrollAnchor(line: 1, 10), ScrollAnchor(line: 3, 300),
                                      ScrollAnchor(line: 9, 1500), ScrollAnchor(line: 5, 2000)],
                            editorEnd: 1000, previewEnd: 3000)
        // Line 3 has no editor anchor; line 5 after 9 isn't increasing.
        #expect(map.pairs.map(\.editor) == [0, 400, 1000])
        #expect(map.pairs.map(\.preview) == [0, 1500, 3000])
    }


}

extension LiveDocumentTests {
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

    /// Sync scrolling on, and a fixed style.
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

    /// An anchor in the middle of the document (there are many, and early
    /// ones sit in the first screen, where the focus tapers).
    func middleIndex(_ controller: DocumentController) -> Int {
        controller.previewMetrics.anchors.count / 2
    }

    /// The editor and preview positions of the preview's `index`th anchor's
    /// line.
    func anchorPair(_ controller: DocumentController, _ index: Int) -> (editor: CGFloat, preview: CGFloat)? {
        let preview = controller.previewMetrics.anchors
        guard index < preview.count,
              let editor = controller.editorAnchors.first(where: { $0.line == preview[index].line })
        else { return nil }
        return (editor.position, preview[index].position)
    }

    /// Both panes anchor on source lines: every block the preview marks, at
    /// its top, and the same line's top in the editor.
    @Test func sourceLinesAlignInBothDirections() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.previewMetrics.anchors.count > 10 })
            let previewLines = controller.previewMetrics.anchors.map(\.line)
            let editorLines = Set(controller.editorAnchors.map(\.line))
            #expect(editorLines == Set(previewLines))

            // A line in the middle: editor top at the center → preview top at center.
            let index = previewLines.count / 2
            let line = previewLines[index]
            let editorY = try #require(controller.editorAnchors.first { $0.line == line }).position
            let previewY = controller.previewMetrics.anchors[index].position
            let editorHeight = controller.editorScrollView.contentView.bounds.height
            let previewHeight = controller.previewMetrics.visibleHeight
            let clipView = controller.editorScrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: editorY - editorHeight / 2))
            controller.editorScrollView.reflectScrolledClipView(clipView)
            #expect(await waitUntil {
                abs(await previewScrollY(controller) - (previewY - previewHeight / 2)) < 2
            })

            // And back: another line centered in the preview → centered in
            // the editor.
            try await Task.sleep(for: .milliseconds(400))
            let index2 = previewLines.count / 3
            let line2 = previewLines[index2]
            let previewY2 = controller.previewMetrics.anchors[index2].position
            let editorY2 = try #require(controller.editorAnchors.first { $0.line == line2 }).position
            let target = previewY2 - previewHeight / 2
            _ = try await controller.preview.webView.evaluateJavaScript("window.scrollTo(0, \(target)); 0")
            controller.preview.pageDidScroll(to: target)
            #expect(await waitUntil { abs(clipView.bounds.minY - (editorY2 - editorHeight / 2)) < 2 })
        }
    }

    /// Phase 4 check: help.md (with its fence-in-code-span case) and the
    /// image-heavy corpus document stay aligned with unequal pane widths,
    /// in both directions, at several points.
    @Test(arguments: ["help.md", "19-images.md"])
    func documentsStayAligned(_ name: String) async throws {
        try await withSyncScrolling {
            let document = try #require(try Corpus.all().first { $0.name == name })
            let controller = DocumentController(
                document: MarkdownDocument(text: document.text),
                fileURL: document.baseURL?.appending(path: name))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let split = NSSplitView(frame: window.contentView!.bounds)
            split.isVertical = true
            split.addArrangedSubview(controller.editorScrollView)
            split.addArrangedSubview(controller.preview.webView)
            window.contentView = split
            split.adjustSubviews()
            split.setPosition(300, ofDividerAt: 0)
            controller.viewDidAppear()
            defer { controller.tearDown(); window.close() }

            #expect(await waitUntil { controller.previewMetrics.anchors.count > 5 })
            // Let images load and lay out, then re-measure.
            #expect(await waitUntil(timeout: 15) {
                (try? await controller.preview.webView.evaluateJavaScript(
                    "Array.from(document.images).every(i => i.complete)")) as? Bool == true
            })
            controller.preview.pageLayoutDidChange()
            try await Task.sleep(for: .milliseconds(500))

            let anchors = controller.previewMetrics.anchors
            let editorHeight = controller.editorScrollView.contentView.bounds.height
            let previewHeight = controller.previewMetrics.visibleHeight
            let clipView = controller.editorScrollView.contentView
            for fraction in [0.3, 0.5, 0.7] {
                let index = Int(Double(anchors.count) * fraction)
                let line = anchors[index].line
                guard let editorY = controller.editorAnchors.first(where: { $0.line == line })?.position
                else { Issue.record("no line anchor at \(fraction)"); continue }
                let previewY = anchors[index].position
                clipView.scroll(to: NSPoint(x: 0, y: editorY - editorHeight / 2))
                controller.editorScrollView.reflectScrolledClipView(clipView)
                #expect(await waitUntil {
                    abs(await previewScrollY(controller) - (previewY - previewHeight / 2)) < 2
                }, "editor → preview at line \(line)")
                try await Task.sleep(for: .milliseconds(400))
                // The page scrolls by whole pixels.
                let target = (previewY - previewHeight / 2).rounded()
                _ = try await controller.preview.webView.evaluateJavaScript("window.scrollTo(0, \(target)); 0")
                controller.preview.pageDidScroll(to: target)
                // The line at the editor's focus: its middle, or nearer the
                // top or bottom within the editor's first or last screen.
                let editorGeometry = ScrollGeometry(
                    contentHeight: controller.editorScrollView.documentView?.bounds.height ?? 0,
                    visibleHeight: editorHeight)
                // Within half an editor line: where a short preview block
                // faces a long wrapped one, a pixel of the page is many in
                // the editor.
                #expect(await waitUntil {
                    abs(clipView.bounds.minY - editorGeometry.offset(forFocus: editorY)) < 12
                }, "preview → editor at line \(line)")
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    @Test
    func resizingKeepsAlignment() async throws {
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
            let pair = try #require(anchorPair(controller, middleIndex(controller)))
            clipView.scroll(to: NSPoint(x: 0, y: pair.editor - editorHeight / 2))
            controller.editorScrollView.reflectScrolledClipView(clipView)
            let expected = pair.preview - previewHeight / 2
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

    @Test
    func rerenderKeepsPositionWhenPreviewLeads() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            let ok1 = await waitUntil { controller.previewMetrics.anchors.count > 0 }
            #expect(ok1)
            let previewHeight = controller.previewMetrics.visibleHeight
            let previewY = controller.previewMetrics.anchors[middleIndex(controller)].position
                - previewHeight / 2
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

    // MARK: - Smooth scrolling

    func evaluate(_ controller: DocumentController, _ script: String) async -> Any? {
        try? await controller.preview.webView.evaluateJavaScript(script)
    }

    @Test func easingClosesTheDistanceAndEnds() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.preview.isReady && !controller.preview.isLoading })

            // One 60 Hz frame covers part of the way, never overshooting.
            let first = await evaluate(controller, "MacDownScroll.step(0, 1000, 16.7)") as? Double ?? 0
            #expect(first > 100 && first < 400)
            #expect(await evaluate(controller, "MacDownScroll.step(1000, 0, 16.7)") as? Double
                    == 1000 - first)
            // A pixel at least, and the target once within a pixel.
            #expect(await evaluate(controller, "MacDownScroll.step(0, 2, 1)") as? Double == 1)
            #expect(await evaluate(controller, "MacDownScroll.step(99.5, 100, 16.7)") as? Double
                    == 100)
            // Frame by frame, the page arrives within a few hundred ms.
            let frames = await evaluate(controller, """
                var y = 0, n = 0;
                while (y !== 3000 && n < 1000) { y = MacDownScroll.step(y, 3000, 16.7); n++; }
                n
                """) as? Int ?? 0
            #expect(frames > 5 && frames < 40, "\(frames) frames")
        }
    }

    @Test func animatedScrollArrivesWithoutAnimationFrames() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.preview.isReady && !controller.preview.isLoading })
            // Test windows aren't drawn, like hidden ones; the page jumps
            // to the target rather than waiting for frames.
            controller.preview.scroll(to: 400, animated: true)
            #expect(await waitUntil { await previewScrollY(controller) == 400 })
            // Instant scrolling cancels a glide in progress.
            controller.preview.scroll(to: 900, animated: true)
            controller.preview.scroll(to: 200)
            #expect(await waitUntil { await previewScrollY(controller) == 200 })
            try await Task.sleep(for: .milliseconds(300))
            #expect(await previewScrollY(controller) == 200)
        }
    }

    @Test func pageFollowingTheEditorDoesNotLead() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.previewMetrics.anchors.count > 0 })
            let clipView = controller.editorScrollView.contentView
            let before = clipView.bounds.minY
            // The page's own scrolling is reported as such and ignored...
            controller.preview.pageDidScroll(to: 1500, byUser: false)
            #expect(clipView.bounds.minY == before)
            #expect(controller.preview.lastScrollTop == 1500)
            // ...while the user's moves the editor.
            controller.preview.pageDidScroll(to: 1500)
            #expect(clipView.bounds.minY != before)
        }
    }


    /// WebKit draws no frames for test windows; frames from a timer let the
    /// page's real animation loop run. Counts frames in `window.frameCount`.
    func installFrameShim(_ controller: DocumentController) async {
        _ = await evaluate(controller, """
            window.frameCount = 0;
            window.requestAnimationFrame = function (callback) {
              return setTimeout(function () {
                window.frameCount++;
                callback(performance.now());
              }, 16);
            };
            window.cancelAnimationFrame = clearTimeout;
            0
            """)
    }

    /// The page's offsets every 20 ms until it's been still for 200 ms.
    func sampleUntilStill(_ controller: DocumentController) async throws -> [CGFloat] {
        var samples: [CGFloat] = [await previewScrollY(controller)]
        var still = 0
        while still < 10, samples.count < 500 {
            try await Task.sleep(for: .milliseconds(20))
            let y = await previewScrollY(controller)
            still = y == samples.last ? still + 1 : 0
            samples.append(y)
        }
        return samples
    }

    @Test func glidesThroughIntermediateOffsets() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.previewMetrics.anchors.count > 0 })
            await installFrameShim(controller)
            var reports = 0
            let onScroll = controller.preview.onScroll
            controller.preview.onScroll = { reports += 1; onScroll?($0) }

            controller.preview.scroll(to: 1500, animated: true)
            let samples = try await sampleUntilStill(controller)
            #expect(samples.last == 1500)
            #expect(samples.contains { $0 > 0 && $0 < 1500 }, "\(samples)")
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "\(samples)")
            // Moving under its own steam, the page doesn't lead the editor.
            #expect(reports == 0)

            // The user scrolling it does.
            _ = await evaluate(controller, "window.scrollTo(0, 300); 0")
            #expect(await waitUntil { reports > 0 })
        }
    }

    @Test func glideFollowsAMovingTarget() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.previewMetrics.anchors.count > 0 })
            await installFrameShim(controller)
            controller.preview.scroll(to: 1500, animated: true)
            try await Task.sleep(for: .milliseconds(60))
            controller.preview.scroll(to: 600, animated: true)
            let samples = try await sampleUntilStill(controller)
            #expect(samples.last == 600, "\(samples)")

            // Past the end of the page it stops at the end, and stops asking
            // for frames.
            controller.preview.scroll(to: 1_000_000, animated: true)
            let end = try await sampleUntilStill(controller).last ?? 0
            let max = await evaluate(controller,
                "document.documentElement.scrollHeight - window.innerHeight") as? Double ?? -1
            #expect(abs(end - CGFloat(max)) < 1)
            let frames = await evaluate(controller, "window.frameCount") as? Int ?? 0
            try await Task.sleep(for: .milliseconds(200))
            #expect(await evaluate(controller, "window.frameCount") as? Int == frames)
        }
    }

    @Test func clickFinishesTheGlide() async throws {
        try await withSyncScrolling {
            let (controller, window) = makeController()
            defer { controller.tearDown(); window.close() }
            #expect(await waitUntil { controller.previewMetrics.anchors.count > 0 })
            await installFrameShim(controller)
            controller.preview.scroll(to: 1500, animated: true)
            try await Task.sleep(for: .milliseconds(40))
            _ = await evaluate(controller,
                "window.dispatchEvent(new MouseEvent('mousedown')); 0")
            #expect(await previewScrollY(controller) == 1500)
        }
    }
}
}

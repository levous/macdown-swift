//
//  HelpDocumentTests.swift
//  MacDownKitTests
//
//  The bundled help (Resources/help.md) demonstrates every Markdown feature
//  with a live example, so it doubles as the end-to-end fixture: these tests
//  check that each example renders, is highlighted in the editor, and works in
//  the real preview. Keep help.md and these tests in step when features change.
//

import AppKit
import CPegMarkdown
import Foundation
import Testing
@testable import MacDownKit

enum HelpDocument {
    static func text() throws -> String {
        let url = try #require(MPPaths.resourceBundle.url(forResource: "help",
                                                          withExtension: "md"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor @Suite struct HelpDocumentRenderingTests {
    /// Renders the help with preferences in a throwaway suite, with either
    /// engine. Entities are decoded so hoedown's `&ldquo;` and cmark-gfm's
    /// `“` compare alike.
    func render(_ engine: MarkdownEngine,
                _ configure: (Preferences) -> Void = { _ in }) throws -> String {
        let suite = "MacDownHelpTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)    // fresh-install defaults
        configure(preferences)
        let settings = preferences.renderSettings.parse
        let html = switch engine {
        case .hoedown: MarkdownParser.parse(try HelpDocument.text(), settings: settings).body
        case .swiftMarkdown: MarkdownDocumentModel(try HelpDocument.text(), options: .init(settings)).body
        }
        return HTMLDiff.decodeEntities(html)
    }

    @Test(arguments: MarkdownEngine.allCases)
    func standardMarkdownRendersWithDefaultSettings(_ engine: MarkdownEngine) throws {
        let html = try render(engine)
        for element in ["<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<strong>", "<em>",
                        "<u>Underline</u>", "<code>Inline code</code>", "<pre>",
                        "<blockquote>", "<ol>", "<ul>", "<hr>", "<table>",
                        "<kbd>Command</kbd>", "H<sub>2</sub>O", "©",
                        "<del>struck through</del>", "task-list-item", "So A<em>maz</em>ing",
                        #"<a name="standard-extensions"></a>"#,
                        "<!-- This is an HTML comment."] {
            #expect(html.contains(element), "missing \(element)")
        }
        // Task lists are standard: all four example items are checkboxes.
        #expect(html.components(separatedBy: #"type="checkbox""#).count - 1 == 4)
        // Nested block quotes, inline and reference links and images.
        #expect(html.components(separatedBy: "<blockquote>").count - 1 >= 3)
        #expect(html.contains(#"<a href="https://commonmark.org" title="The CommonMark site">"#))
        #expect(html.contains(#"<a href="https://commonmark.org" title="Title">a link</a>"#))
        #expect(html.contains(#"<a href="https://spec.commonmark.org">like this</a>"#))
        #expect(html.components(separatedBy: #"<img src="data:image/svg+xml;base64,"#).count - 1 == 2)
        // Fenced code with languages, and the custom accessory label.
        for language in ["swift", "javascript", "python", "mermaid", "dot"] {
            #expect(html.contains(#"class="language-\#(language)""#), "missing \(language) block")
        }
        // Footnotes are on by default.
        #expect(html.contains(#"<div class="footnotes">"#))
        // Escapes stay literal.
        #expect(html.contains("*not emphasized*"))
    }

    // The live examples in "Inline Formatting" use their own text: the table
    // above them shows each result as literal HTML.

    @Test(arguments: MarkdownEngine.allCases)
    func extendedSyntaxStaysPlainUntilTurnedOn(_ engine: MarkdownEngine) throws {
        let html = try render(engine)
        for element in ["<mark>highlighted</mark>", "y<sup>3</sup>", #"<a href="https://example.org">"#, "<q>"] {
            #expect(!html.contains(element), "\(element) without its setting")
        }
        for text in ["==highlighted==", "y^3", "https://example.org", "<p>[TOC]</p>",
                     "&quot;Curly quotes,&quot;", "an ellipsis..."] {
            #expect(html.contains(text), "\(text) should show as typed")
        }
    }

    @Test(arguments: MarkdownEngine.allCases)
    func everyOptionRendersItsExample(_ engine: MarkdownEngine) throws {
        let html = try render(engine) { p in
            p.extensionHighlight = true
            p.extensionSuperscript = true
            p.extensionAutolink = true
            p.extensionSmartyPants = true
            p.htmlRendersTOC = true
            p.htmlMathJax = true
            p.htmlMathJaxInlineDollar = true
        }
        for element in ["<mark>highlighted</mark>", "y<sup>3</sup>", "10<sup>-6</sup>",
                        "“Curly quotes,”",
                        #"<a href="https://example.org">https://example.org</a>"#,
                        #"<a href="mailto:hello@example.org">"#,
                        "–", "—", "…"] {
            #expect(html.contains(element), "missing \(element)")
        }
        // [TOC] became a table of contents.
        #expect(!html.contains("<p>[TOC]</p>"))
        // Math is left for MathJax, untouched by superscript or emphasis.
        #expect(html.contains("A^T_S = B"))
        #expect(html.contains(#"\int_0^1 x^2"#))
    }
}

@Suite struct HelpDocumentHighlightingTests {
    @Test(arguments: MarkdownEngine.allCases)
    func editorHighlightsEveryElementType(_ engine: MarkdownEngine) throws {
        let elements = highlightElements(try HelpDocument.text(), engine: engine)
        var types: [(String, pmh_element_type)] = [
            ("H1", pmh_H1), ("H2", pmh_H2), ("H3", pmh_H3), ("H4", pmh_H4),
            ("H5", pmh_H5), ("H6", pmh_H6), ("EMPH", pmh_EMPH), ("STRONG", pmh_STRONG),
            ("CODE", pmh_CODE), ("VERBATIM", pmh_VERBATIM), ("LINK", pmh_LINK),
            ("AUTO_LINK_URL", pmh_AUTO_LINK_URL), ("AUTO_LINK_EMAIL", pmh_AUTO_LINK_EMAIL),
            ("IMAGE", pmh_IMAGE), ("REFERENCE", pmh_REFERENCE), ("BLOCKQUOTE", pmh_BLOCKQUOTE),
            ("LIST_BULLET", pmh_LIST_BULLET), ("LIST_ENUMERATOR", pmh_LIST_ENUMERATOR),
            ("HRULE", pmh_HRULE), ("HTML", pmh_HTML), ("HTML_ENTITY", pmh_HTML_ENTITY),
            ("COMMENT", pmh_COMMENT),
        ]
        // PEG Markdown Highlight defines NOTE but never emits it; the new
        // engine colors footnotes.
        if engine == .swiftMarkdown { types.append(("NOTE", pmh_NOTE)) }
        for (name, type) in types {
            #expect(!elements.spans[Int(type.rawValue)].isEmpty, "no \(name) spans")
        }
    }

    /// The opt-in types appear with their settings on (new engine only).
    @Test func optInTypesWithTheirSettings() throws {
        let model = MarkdownDocumentModel(try HelpDocument.text(), options: .init(
            math: true, inlineDollar: true, highlight: true, superscript: true))
        for name in ["MATH", "HIGHLIGHT", "SUPERSCRIPT"] {
            let type = try #require(ThemeStyle.elementNames.firstIndex(of: name))
            #expect(!model.highlights.spans[type].isEmpty, "no \(name) spans")
        }
    }
}

extension LiveDocumentTests {
@MainActor @Suite(.serialized) struct HelpDocumentPreviewTests {
    func waitUntil(timeout: Double = 20, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test(arguments: MarkdownEngine.allCases)
    func previewRunsEveryExample(_ engine: MarkdownEngine) async throws {
        let p = Preferences.shared
        let saved = (p.htmlSyntaxHighlighting, p.htmlMermaid, p.htmlGraphviz, p.markdownEngine)
        p.htmlSyntaxHighlighting = true
        p.htmlMermaid = true
        p.htmlGraphviz = true
        p.markdownEngine = engine
        defer { (p.htmlSyntaxHighlighting, p.htmlMermaid, p.htmlGraphviz, p.markdownEngine) = saved }
        let controller = DocumentController(
            document: MarkdownDocument(text: try HelpDocument.text()), fileURL: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(controller.editorScrollView)
        split.addArrangedSubview(controller.preview.webView)
        window.contentView = split
        controller.viewDidAppear()
        defer { controller.tearDown(); window.close() }

        func evaluate(_ script: String) async -> Any? {
            try? await controller.preview.webView.evaluateJavaScript(script)
        }
        func count(_ selector: String) async -> Int {
            await evaluate("document.querySelectorAll('\(selector)').length") as? Int ?? -1
        }

        // All three Mermaid diagrams draw, without errors.
        let diagrams = await waitUntil { await count(".mermaid-diagram > svg") == 3 }
        let drawn = await count(".mermaid-diagram > svg")
        #expect(diagrams, "Mermaid diagrams drawn: \(drawn)")
        #expect(await count(".mermaid-error") == 0)
        // Graphviz replaces its code block with a graph.
        #expect(await count("code.language-dot") == 0)
        #expect(await evaluate("Array.from(document.querySelectorAll('svg text')).some(t => t.textContent === 'Preview')") as? Bool == true)
        // Prism colors each language.
        for language in ["swift", "javascript", "python"] {
            #expect(await count("code.language-\(language) .token") > 0, "\(language) not highlighted")
        }
        // The embedded images load.
        let images = await waitUntil {
            await evaluate("Array.from(document.images).every(i => i.complete && i.naturalWidth > 0)") as? Bool == true
        }
        #expect(images)
        #expect(await count("img") == 2)
        // Task list checkboxes are shown, and disabled.
        #expect(await count("input[type=checkbox]") == 4)
        #expect(await count("input[type=checkbox]:disabled") == 4)
    }
}
}

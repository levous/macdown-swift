//
//  EditorTests.swift
//  MacDown
//

import AppKit
import CPegMarkdown
import Testing
@testable import MacDownKit

/// Highlight spans from either engine: PEG, or the swift-markdown model.
func highlightElements(_ text: String, engine: MarkdownEngine) -> HighlightElements {
    switch engine {
    case .hoedown: HighlightElements.parse(text, extensions: Int32(pmh_EXT_NOTES.rawValue))
    case .cmarkGfm: MarkdownDocumentModel(text, options: .init()).highlights
    }
}

@Suite struct HighlighterTests {
    @Test(arguments: MarkdownEngine.allCases)
    func parsesElements(_ engine: MarkdownEngine) {
        let elements = highlightElements("# Title\n\n*em* and **strong**\n", engine: engine)
        #expect(elements.spans[Int(pmh_H1.rawValue)].count == 1)
        #expect(elements.spans[Int(pmh_EMPH.rawValue)].count == 1)
        #expect(elements.spans[Int(pmh_STRONG.rawValue)].count == 1)
    }

    @Test(arguments: MarkdownEngine.allCases)
    func convertsSurrogatePairOffsets(_ engine: MarkdownEngine) {
        let elements = highlightElements("😀 *em*\n", engine: engine)
        let span = elements.spans[Int(pmh_EMPH.rawValue)].first
        // "😀" is two UTF-16 units; "*em*" starts at UTF-16 offset 3.
        #expect(span?.pos == 3)
        #expect(span?.end == 7)
    }

    @MainActor @Test(arguments: MarkdownEngine.allCases)
    func appliesStylesToTextView(_ engine: MarkdownEngine) async throws {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = "# Title\n\n*em*\n"
        let highlighter = MarkdownHighlighter(textView: textView)
        let errors = highlighter.applyStyles(fromStylesheet: "H1\nforeground: ff0000\n")
        #expect(errors.isEmpty)
        highlighter.usesExternalElements = engine == .cmarkGfm
        highlighter.activate()
        try await Task.sleep(for: .milliseconds(500))
        if engine == .cmarkGfm {
            // As after a parse: spans arrive once the text is laid out.
            highlighter.update(highlightElements(textView.string, engine: engine))
        }
        let color = textView.textStorage?.attribute(.foregroundColor, at: 2,
                                                    effectiveRange: nil) as? NSColor
        #expect(color?.usingColorSpace(.deviceRGB)?.redComponent == 1.0)
    }
}

@MainActor @Suite struct ThemeApplicationTests {
    @Test func appliesABundledTheme() throws {
        let url = try #require(MPPaths.resourceBundle.url(forResource: "Solarized (Dark)",
                                                          withExtension: "style",
                                                          subdirectory: "Themes"))
        let stylesheet = try String(contentsOf: url, encoding: .utf8)
        let theme = ThemeStyle(parsing: stylesheet)
        let (_, textView) = EditorTextView.makeScrollableEditor()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = "# Title\n"
        let highlighter = MarkdownHighlighter(textView: textView)
        #expect(highlighter.applyStyles(fromStylesheet: stylesheet).isEmpty)

        guard case .backgroundColor(let background)? = theme.editor
            .first(where: { if case .backgroundColor = $0.value { true } else { false } })?.value
        else { Issue.record("no editor background"); return }
        #expect(textView.backgroundColor == HighlightingStyle.color(background))
        let h1 = try #require(highlighter.styles.first { $0.elementType == Int(pmh_H1.rawValue) })
        let rule = try #require(theme.elements.first { $0.element == "H1" })
        let foreground = rule.attributes.compactMap { attribute -> ThemeStyle.Color? in
            if case .foregroundColor(let c) = attribute.value { c } else { nil }
        }.first
        #expect(h1.attributesToAdd[.foregroundColor] as? NSColor
                == foreground.map(HighlightingStyle.color))
    }

    @Test func reportsStylesheetErrors() {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        let highlighter = MarkdownHighlighter(textView: textView)
        #expect(highlighter.applyStyles(fromStylesheet: "H1\ncolor: 12\nfont-style: wavy\n") == [
            "(Line 2): Value '12' is not a valid color value: it should be a hexadecimal number, 6 or 8 characters long.",
            "(Line 3): Value 'wavy' is invalid for attribute 'font-style'",
        ])
    }
}

@MainActor
@Suite struct AutocompleteTests {
    func makeTextView(_ text: String, selection: NSRange? = nil) -> NSTextView {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = text
        textView.setSelectedRange(selection
            ?? NSRange(location: (text as NSString).length, length: 0))
        return textView
    }

    @Test func toggleStrong() {
        let tv = makeTextView("hello world", selection: NSRange(location: 6, length: 5))
        #expect(tv.toggleForMarkup(prefix: "**", suffix: "**"))
        #expect(tv.string == "hello **world**")
        #expect(tv.selectedRange() == NSRange(location: 8, length: 5))
        #expect(!tv.toggleForMarkup(prefix: "**", suffix: "**"))
        #expect(tv.string == "hello world")
        #expect(tv.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func emphasisDoesNotUnwrapStrong() {
        let tv = makeTextView("**a**", selection: NSRange(location: 2, length: 1))
        #expect(tv.toggleForMarkup(prefix: "*", suffix: "*"))
        #expect(tv.string == "***a***")
    }

    @Test func makeHeader() {
        let tv = makeTextView("Title\n", selection: NSRange(location: 0, length: 0))
        tv.makeHeaderForSelectedLines(level: 2)
        #expect(tv.string == "## Title\n")
        tv.makeHeaderForSelectedLines(level: 1)
        #expect(tv.string == "# Title\n")
        tv.makeHeaderForSelectedLines(level: 0)
        #expect(tv.string == "Title\n")
    }

    @Test func toggleBlockquote() {
        let tv = makeTextView("one\ntwo", selection: NSRange(location: 0, length: 7))
        tv.toggleBlock(pattern: "^> \\S", prefix: "> ")
        #expect(tv.string == "> one\n> two")
        tv.toggleBlock(pattern: "^> \\S", prefix: "> ")
        #expect(tv.string == "one\ntwo")
    }

    @Test func indentAndUnindent() {
        let tv = makeTextView("a\nb", selection: NSRange(location: 0, length: 3))
        tv.indentSelectedLines(padding: "    ")
        #expect(tv.string == "    a\n    b")
        tv.unindentSelectedLines()
        #expect(tv.string == "a\nb")
    }

    @Test func continuesUnorderedList() {
        let tv = makeTextView("- item")
        #expect(tv.completeNextListItem(autoIncrement: true))
        #expect(tv.string == "- item\n- ")
    }

    @Test func continuesOrderedListWithIncrement() {
        let tv = makeTextView("  1. first")
        #expect(tv.completeNextListItem(autoIncrement: true))
        #expect(tv.string == "  1. first\n  2. ")
    }

    @Test func emptyListItemEndsList() {
        let tv = makeTextView("- item\n- ")
        #expect(tv.completeNextListItem(autoIncrement: true))
        #expect(tv.string == "- item\n\n")
    }

    @Test func continuesBlockquote() {
        let tv = makeTextView("> quote")
        #expect(tv.completeNextBlockquoteLine())
        #expect(tv.string == "> quote\n> ")
    }

    @Test func continuesIndentation() {
        let tv = makeTextView("    code")
        #expect(tv.completeNextIndentedLine())
        #expect(tv.string == "    code\n    ")
    }

    @Test func completesMatchingCharacters() {
        let tv = makeTextView("", selection: NSRange(location: 0, length: 0))
        #expect(tv.completeMatchingCharacters(forTextIn: NSRange(location: 0, length: 0),
                                              with: "(", strikethroughEnabled: false))
        #expect(tv.string == "()")
        #expect(tv.selectedRange().location == 1)
        // Typing the closing character skips over it.
        #expect(tv.completeMatchingCharacters(forTextIn: NSRange(location: 1, length: 0),
                                              with: ")", strikethroughEnabled: false))
        #expect(tv.string == "()")
        #expect(tv.selectedRange().location == 2)
    }

    @Test func wrapsSelection() {
        let tv = makeTextView("word", selection: NSRange(location: 0, length: 4))
        #expect(tv.completeMatchingCharacters(forTextIn: NSRange(location: 0, length: 4),
                                              with: "[", strikethroughEnabled: false))
        #expect(tv.string == "[word]")
        #expect(tv.selectedRange() == NSRange(location: 1, length: 4))
    }

    @Test func deletesMatchingPair() {
        let tv = makeTextView("()", selection: NSRange(location: 1, length: 0))
        #expect(tv.deleteMatchingCharacters(around: 1))
        #expect(tv.string == "")
    }

    @Test func insertsSpacesForTab() {
        let tv = makeTextView("ab")
        tv.insertSpacesForTab()
        #expect(tv.string == "ab  ")
    }

    @Test func unindentsSpaces() {
        let tv = makeTextView("        x", selection: NSRange(location: 8, length: 0))
        #expect(tv.unindentForSpaces(before: 8))
        #expect(tv.string == "    x")
    }
}

extension LiveDocumentTests {
@MainActor @Suite struct EditorHighlightingSetupTests {
    /// Footnotes are standard, so the editor always parses them (the old
    /// `extensionFootnotes` setting had this inverted).
    @Test func highlighterAlwaysParsesFootnotes() {
        let controller = DocumentController(document: MarkdownDocument(text: "a[^1]\n\n[^1]: b\n"),
                                            fileURL: nil)
        defer { controller.tearDown() }
        controller.setupEditor(nil)
        #expect(controller.highlighter.extensions == Int32(pmh_EXT_NOTES.rawValue))
    }
}
}

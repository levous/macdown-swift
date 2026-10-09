//
//  EditorTests.swift
//  MacDown
//

import AppKit
import CPegMarkdown
import Testing
@testable import MacDownKit

@Suite struct HighlighterTests {
    @Test func parsesElements() {
        let elements = HighlightElements.parse("# Title\n\n*em* and **strong**\n",
                                               extensions: 0)
        #expect(elements.spans[Int(pmh_H1.rawValue)].count == 1)
        #expect(elements.spans[Int(pmh_EMPH.rawValue)].count == 1)
        #expect(elements.spans[Int(pmh_STRONG.rawValue)].count == 1)
    }

    @Test func convertsSurrogatePairOffsets() {
        let elements = HighlightElements.parse("😀 *em*\n", extensions: 0)
        let span = elements.spans[Int(pmh_EMPH.rawValue)].first
        // "😀" is two UTF-16 units; "*em*" starts at UTF-16 offset 3.
        #expect(span?.pos == 3)
        #expect(span?.end == 7)
    }

    @MainActor @Test func appliesStylesToTextView() async throws {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = "# Title\n\n*em*\n"
        let highlighter = MarkdownHighlighter(textView: textView)
        let errors = highlighter.applyStyles(fromStylesheet: "H1\nforeground: ff0000\n")
        #expect(errors.isEmpty)
        highlighter.activate()
        try await Task.sleep(for: .milliseconds(500))
        let color = textView.textStorage?.attribute(.foregroundColor, at: 2,
                                                    effectiveRange: nil) as? NSColor
        #expect(color?.redComponent == 1.0)
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

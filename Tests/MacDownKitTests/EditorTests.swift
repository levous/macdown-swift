//
//  EditorTests.swift
//  MacDown
//

import AppKit
import Testing

@testable import MacDownKit

/// Whether a color is the stylesheets' ff0000. Checking only the red
/// component would also match white, the default text color in Dark Mode.
func isPureRed(_ color: NSColor?) -> Bool {
    guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
    return color.redComponent == 1 && color.greenComponent == 0 && color.blueComponent == 0
}

/// The document model's highlight spans for `text`.
func highlightElements(_ text: String) -> HighlightElements {
    MarkdownDocumentModel(text, options: .init()).highlights
}

@Suite struct HighlighterTests {
    @Test
    func parsesElements() {
        let elements = highlightElements("# Title\n\n*em* and **strong**\n")
        #expect(elements.spans[HighlightElement.h1.rawValue].count == 1)
        #expect(elements.spans[HighlightElement.emph.rawValue].count == 1)
        #expect(elements.spans[HighlightElement.strong.rawValue].count == 1)
    }

    /// The element types index the themes' element names.
    @Test func elementTypesFollowTheThemeNames() {
        #expect(HighlightElement.allCases.count == ThemeStyle.elementNames.count)
        for (element, name) in [(HighlightElement.link, "LINK"), (.autoLinkEmail, "AUTO_LINK_EMAIL"),
                                (.h1, "H1"), (.h6, "H6"), (.htmlBlock, "HTMLBLOCK"), (.note, "NOTE"),
                                (.superscript, "SUPERSCRIPT")] {
            #expect(ThemeStyle.elementNames[element.rawValue] == name)
        }
    }

    /// Footnotes are standard, so they're always highlighted.
    @Test func footnotes() {
        #expect(!highlightElements("a[^1]\n\n[^1]: b\n").spans[HighlightElement.note.rawValue].isEmpty)
    }

    @Test
    func convertsSurrogatePairOffsets() {
        let elements = highlightElements("😀 *em*\n")
        let span = elements.spans[HighlightElement.emph.rawValue].first
        // "😀" is two UTF-16 units; "*em*" starts at UTF-16 offset 3.
        #expect(span?.pos == 3)
        #expect(span?.end == 7)
    }

    @MainActor @Test
    func appliesStylesToTextView() async throws {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = "# Title\n\n*em*\n"
        let highlighter = MarkdownHighlighter(textView: textView)
        let errors = highlighter.applyStyles(fromStylesheet: "H1\nforeground: ff0000\n")
        #expect(errors.isEmpty)
        highlighter.activate()
        // As after a parse: spans arrive once the text is laid out.
        highlighter.update(highlightElements(textView.string))
        func red() -> Bool {
            isPureRed(textView.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)
        }
        // Off screen nothing is visible, so the idle pass styles the text.
        func waitForRed() async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !red(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            return red()
        }
        #expect(try await waitForRed())
        // Settings changes deactivate and reactivate the highlighter, which
        // restyles from the spans it has (there's no parse of its own).
        highlighter.deactivate()
        highlighter.clearHighlighting()
        #expect(!red())
        highlighter.activate()
        #expect(try await waitForRed())
    }
}

/// Highlighting what scrolls into view without delay, and the rest of the
/// document in the background.
@MainActor @Suite struct IncrementalHighlightingTests {
    /// Sections of a heading and a few paragraphs, many screens long.
    static let text = (1...200).map {
        "# Heading \($0)\n\nSome *emphasis* in paragraph \($0).\n\nMore text.\n"
    }.joined(separator: "\n")

    func makeHighlighter(_ stylesheet: String = "H1\nforeground: ff0000\n")
        -> (MarkdownHighlighter, NSScrollView, NSTextView, NSWindow) {
        let (scrollView, textView) = EditorTextView.makeScrollableEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        window.layoutIfNeeded()
        textView.string = Self.text
        let highlighter = MarkdownHighlighter(textView: textView)
        highlighter.applyStyles(fromStylesheet: stylesheet)
        highlighter.activate()
        return (highlighter, scrollView, textView, window)
    }

    func isRed(_ textView: NSTextView, at location: Int) -> Bool {
        isPureRed(textView.textStorage?.attribute(.foregroundColor, at: location,
                                                  effectiveRange: nil) as? NSColor)
    }

    func location(of string: String) -> Int {
        (Self.text as NSString).range(of: string).location
    }

    func waitForIdlePass(_ highlighter: MarkdownHighlighter, length: Int) async throws {
        for _ in 0..<500 where highlighter.highlightedRanges.count < length {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func highlightsTextScrolledIntoViewRightAway() {
        let (highlighter, scrollView, textView, window) = makeHighlighter()
        defer { withExtendedLifetime(window) {} }
        highlighter.idleStartDate = .distantFuture    // No idle pass.
        highlighter.update(highlightElements(Self.text))
        let far = location(of: "# Heading 150\n") + 2
        #expect(!isRed(textView, at: far))

        textView.scrollRangeToVisible(NSRange(location: far, length: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(isRed(textView, at: far))
        // So is the text a screen past the visible area.
        #expect(isRed(textView, at: location(of: "# Heading 155\n") + 2))
        #expect(!isRed(textView, at: location(of: "# Heading 199\n") + 2))
    }

    @Test func highlightsTheRestWhenIdle() async throws {
        let (highlighter, _, textView, window) = makeHighlighter()
        defer { withExtendedLifetime(window) {} }
        var finished = 0
        highlighter.onIdlePassFinished = { finished += 1 }
        highlighter.update(highlightElements(Self.text))
        let length = (Self.text as NSString).length
        #expect(highlighter.highlightedRanges.count < length / 4)
        try await waitForIdlePass(highlighter, length: length)
        #expect(highlighter.highlightedRanges.count == length)
        #expect(isRed(textView, at: location(of: "# Heading 200\n") + 2))
        #expect(finished == 1)
        #expect(!highlighter.isInIdlePass)
    }

    @Test func editsInvalidateWhatWasHighlighted() {
        let (highlighter, _, textView, window) = makeHighlighter()
        defer { withExtendedLifetime(window) {} }
        highlighter.idleStartDate = .distantFuture
        highlighter.update(highlightElements(Self.text))
        #expect(!highlighter.highlightedRanges.isEmpty)
        // Directly, as typing would also scroll, and so highlight what's
        // visible again.
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        #expect(highlighter.highlightedRanges.isEmpty)
    }

    @Test func hiddenEditorLeavesHighlightingToTheIdlePass() async throws {
        let (highlighter, scrollView, _, window) = makeHighlighter()
        defer { withExtendedLifetime(window) {} }
        scrollView.removeFromSuperview()
        scrollView.frame = .zero
        highlighter.update(highlightElements(Self.text))
        #expect(highlighter.highlightedRanges.isEmpty)
        let length = (Self.text as NSString).length
        try await waitForIdlePass(highlighter, length: length)
        #expect(highlighter.highlightedRanges.count == length)
    }

    @Test func keepsVisibleTextInPlaceWhenTextAboveChangesSize() async throws {
        let (highlighter, scrollView, textView, window) =
            makeHighlighter("H1\nforeground: ff0000\nfont-size: 40px\n")
        defer { withExtendedLifetime(window) {} }
        let target = location(of: "# Heading 120\n")
        textView.scrollRangeToVisible(NSRange(location: target, length: 1))
        let layoutManager = try #require(textView.layoutManager)
        func top() -> CGFloat {
            let glyph = layoutManager.glyphIndexForCharacter(at: target)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                - scrollView.contentView.bounds.minY
        }
        highlighter.update(highlightElements(Self.text))
        let before = top()
        try await waitForIdlePass(highlighter, length: (Self.text as NSString).length)
        // The headings above grew, yet the line stays where it was on screen.
        #expect(isRed(textView, at: location(of: "# Heading 1\n") + 2))
        #expect(abs(top() - before) < 1)
    }

    @Test func idleChunksStartAtTheVisibleTextAndEndOnParagraphs() {
        let string = "aaaa\nbbbb\ncccc\n" as NSString
        var missing = IndexSet(integersIn: 0..<string.length)
        missing.remove(integersIn: 5..<10)
        // From the visible text on first, ending at a line end.
        #expect(MarkdownHighlighter.nextChunk(of: missing, after: 7, in: string)
                == NSRange(location: 10, length: 5))
        missing.remove(integersIn: 10..<15)
        // Then backwards from it.
        #expect(MarkdownHighlighter.nextChunk(of: missing, after: 7, in: string)
                == NSRange(location: 0, length: 5))
        #expect(MarkdownHighlighter.nextChunk(of: IndexSet(), after: 0, in: string) == nil)
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
        let h1 = try #require(highlighter.styles.first { $0.elementType == HighlightElement.h1.rawValue })
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

    static let markups: [(prefix: String, suffix: String)] = [
        ("**", "**"), ("*", "*"), ("~~", "~~"), ("`", "`"), ("<u>", "</u>"), ("==", "=="), ("<!--", "-->"),
    ]

    /// Toggles markup with the selection on `selected`, a substring of
    /// `text`; the resulting text and selection.
    func toggled(_ text: String, selecting selected: String, _ markup: (prefix: String, suffix: String))
        -> (text: String, selection: String) {
        let tv = makeTextView(text, selection: (text as NSString).range(of: selected))
        tv.toggleForMarkup(prefix: markup.prefix, suffix: markup.suffix)
        return (tv.string, (tv.string as NSString).substring(with: tv.selectedRange()))
    }

    /// Selecting a whole formatted span, markers included, acts like
    /// selecting its text: the same formatting is removed, not doubled.
    @Test(arguments: 0..<7)
    func wholeSpanActsLikeItsText(_ index: Int) {
        let markup = Self.markups[index]
        let text = "x \(markup.prefix)Header 1\(markup.suffix) y"
        let inner = toggled(text, selecting: "Header 1", markup)
        let whole = toggled(text, selecting: markup.prefix + "Header 1" + markup.suffix, markup)
        #expect(inner.text == "x Header 1 y")
        #expect(whole.text == inner.text)
        #expect(whole.selection == "Header 1")
    }

    /// Every other format is added inside the span, as for its text.
    @Test(arguments: 0..<7)
    func otherFormatsGoInside(_ index: Int) {
        let markup = Self.markups[index]
        for other in Self.markups where other.prefix != markup.prefix {
            let text = "\(markup.prefix)Header 1\(markup.suffix)"
            let inner = toggled(text, selecting: "Header 1", other)
            let whole = toggled(text, selecting: text, other)
            #expect(whole.text == inner.text, "\(markup.prefix) then \(other.prefix)")
            #expect(whole.selection == inner.selection)
        }
    }

    /// Bold and italic, together or nested.
    @Test func strongAndEmphasis() {
        let bold = Self.markups[0], italic = Self.markups[1]
        #expect(toggled("**Header 1**", selecting: "**Header 1**", bold).text == "Header 1")
        #expect(toggled("**Header 1**", selecting: "**Header 1**", italic).text == "***Header 1***")
        #expect(toggled("***Header 1***", selecting: "***Header 1***", bold).text == "*Header 1*")
        #expect(toggled("***Header 1***", selecting: "***Header 1***", italic).text == "**Header 1**")
        #expect(toggled("*Header 1*", selecting: "*Header 1*", bold).text == "***Header 1***")
        #expect(toggled("**a *b* c**", selecting: "**a *b* c**", bold).text == "a *b* c")
        #expect(toggled("*a **b** c*", selecting: "*a **b** c*", italic).text == "a **b** c")
    }

    /// With different markers nested, the one toggled is removed where it
    /// is, outside or inside, and a new one goes inside them all.
    @Test func nestedMixedMarkers() {
        let bold = Self.markups[0], strike = Self.markups[2], code = Self.markups[3], underline = Self.markups[4]
        #expect(toggled("x **~~word~~** y", selecting: "**~~word~~**", bold) == ("x ~~word~~ y", "~~word~~"))
        #expect(toggled("x **~~word~~** y", selecting: "**~~word~~**", strike) == ("x **word** y", "word"))
        #expect(toggled("**<u>x</u>**", selecting: "**<u>x</u>**", bold) == ("<u>x</u>", "<u>x</u>"))
        #expect(toggled("**<u>x</u>**", selecting: "**<u>x</u>**", underline) == ("**x**", "x"))
        #expect(toggled("**~~word~~**", selecting: "**~~word~~**", code) == ("**~~`word`~~**", "word"))
    }

    /// Offsets are UTF-16, so text outside the BMP inside or around the
    /// span doesn't shift the markers.
    @Test func wholeSpansWithEmojiAndAccents() {
        let bold = Self.markups[0], strike = Self.markups[2]
        #expect(toggled("🎉 **café 👩‍💻** ✓", selecting: "**café 👩‍💻**", bold) == ("🎉 café 👩‍💻 ✓", "café 👩‍💻"))
        #expect(toggled("**~~ünïcødé 🚀~~**", selecting: "**~~ünïcødé 🚀~~**", strike) == ("**ünïcødé 🚀**", "ünïcødé 🚀"))
    }

    /// Spans at the very start and end of the document.
    @Test func wholeSpanAtDocumentEdges() {
        let bold = Self.markups[0]
        #expect(toggled("**all**", selecting: "**all**", bold) == ("all", "all"))
        #expect(toggled("start **end**", selecting: "**end**", bold) == ("start end", "end"))
        #expect(toggled("**start** end", selecting: "**start**", bold) == ("start end", "start"))
    }

    /// One Undo puts the whole span back.
    @Test func undoRestoresTheWholeSpan() {
        let tv = makeTextView("x **word** y", selection: NSRange(location: 2, length: 8))
        tv.allowsUndo = true
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        tv.toggleForMarkup(prefix: "**", suffix: "**")
        #expect(tv.string == "x word y")
        tv.undoManager?.undo()
        #expect(tv.string == "x **word** y")
    }

    /// Spaces at the edges of the selection don't count.
    @Test func spacesAroundTheSpan() {
        let result = toggled("x **Header 1** y", selecting: " **Header 1** ", Self.markups[0])
        #expect(result.text == "x Header 1 y")
        #expect(result.selection == "Header 1")
    }

    /// Without one matching pair at both ends, the selection is wrapped as
    /// before: separate spans, or markup at one end only.
    @Test func notOneSpan() {
        let bold = Self.markups[0]
        #expect(toggled("**a** and **b**", selecting: "**a** and **b**", bold).text == "****a** and **b****")
        #expect(toggled("*a* and *b*", selecting: "*a* and *b*", Self.markups[1]).text == "**a* and *b**")
        #expect(toggled("**Header 1", selecting: "**Header 1", bold).text == "****Header 1**")
        #expect(toggled("plain text", selecting: "plain text", bold).text == "**plain text**")
        // Markers alone have no text to keep.
        #expect(toggled("****", selecting: "****", bold).text == "********")
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

/// Images embedded as data URIs (dropped files, pasted data).
@Suite struct ImageMarkupTests {
    @Test func dataURI() {
        #expect(ImageMarkup.dataURI(Data([1, 2, 3]), mime: "image/png") == "![](data:image/png;base64,AQID)")
    }

    @Test func filesAreTypedByExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, mime) in [("a.png", "image/png"), ("b.JPG", "image/jpeg"), ("c.gif", "image/gif"),
                             ("d", "image/jpeg")] {
            let url = directory.appending(path: name)
            try Data([0xFF]).write(to: url)
            #expect(ImageMarkup.dataURI(contentsOf: url) == "![](data:\(mime);base64,/w==)")
        }
        #expect(ImageMarkup.dataURI(contentsOf: directory.appending(path: "missing.png")) == nil)
    }
}

/// Pasting inside a code block pastes plain text: the editor knows
/// where code blocks are from the latest parse, or by scanning for fences
/// when the parse is behind the text.
@MainActor @Suite struct EditorCodeBlockTests {
    func editor(_ text: String, parsed: String? = nil) -> EditorTextView {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        let editor = textView as! EditorTextView
        editor.string = text
        if let parsed {
            editor.documentBlocks = (parsed, MarkdownDocumentModel(parsed, options: .init()).blocks)
        }
        return editor
    }

    func location(of marker: String, in text: String) -> Int {
        (text as NSString).range(of: marker).location
    }

    static let text = "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nOutside\n\n    indented code\n\n~~~\nTILDE\n````\nstill\n~~~\nafter\n"

    @Test(arguments: [true, false])
    func fencedBlocks(parsed: Bool) {
        let text = Self.text
        let editor = editor(text, parsed: parsed ? text : "stale")
        #expect(editor.isInCodeBlock(location(of: "let a", in: text)))
        #expect(editor.isInCodeBlock(location(of: "\nlet b", in: text)))    // the blank line
        #expect(!editor.isInCodeBlock(location(of: "Intro", in: text)))
        #expect(!editor.isInCodeBlock(location(of: "Outside", in: text)))
        // A fence closes only with its own character, at least as long.
        #expect(editor.isInCodeBlock(location(of: "TILDE", in: text)))
        #expect(editor.isInCodeBlock(location(of: "still", in: text)))
        #expect(!editor.isInCodeBlock(location(of: "after", in: text)))
    }

    /// Indented code is known from the parse.
    @Test func indentedBlocks() {
        let text = Self.text
        #expect(editor(text, parsed: text).isInCodeBlock(location(of: "indented code", in: text)))
    }

    /// A fence just typed, before the parse catches up, runs to the end.
    @Test func unclosedFenceJustTyped() {
        let text = "Before\n\n```\n"
        let editor = editor(text, parsed: "Before\n\n")
        #expect(editor.isInCodeBlock((text as NSString).length))
        #expect(!editor.isInCodeBlock(0))
    }
}

extension EditorCodeBlockTests {
    @Test func unclosedFenceFromTheParse() {
        let text = "Before\n\n```\ncode"
        #expect(editor(text, parsed: text).isInCodeBlock((text as NSString).length))
    }
}

/// Pasting formatted text and images. Each test uses its own named
/// pasteboard.
@MainActor @Suite struct EditorPasteTests {
    func editor(_ text: String, selection: NSRange? = nil) -> EditorTextView {
        let (_, textView) = EditorTextView.makeScrollableEditor()
        let editor = textView as! EditorTextView
        editor.string = text
        editor.pasteOptions = pasteTestOptions
        editor.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
        return editor
    }

    func pasteboard(_ types: [NSPasteboard.PasteboardType: String]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, string) in types { item.setString(string, forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    /// Pastes `types` into `editor`; whether it was converted.
    func paste(_ types: [NSPasteboard.PasteboardType: String], into editor: EditorTextView) -> Bool {
        let pasteboard = pasteboard(types)
        defer { pasteboard.releaseGlobally() }
        return editor.pasteConverted(from: pasteboard)
    }

    @Test func inlineParagraph() {
        let editor = editor("Say ")
        #expect(paste([.html: "<p><b>hello</b> world</p>", .string: "hello world"], into: editor))
        #expect(editor.string == "Say **hello** world")
        #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
    }

    @Test func replacesTheSelection() {
        let editor = editor("one two three", selection: NSRange(location: 4, length: 3))
        #expect(paste([.html: "<i>2</i>", .string: "2"], into: editor))
        #expect(editor.string == "one *2* three")
    }

    /// Blocks are set off from the text around them by blank lines.
    @Test func blocksGetBlankLines() {
        let html = "<h1>T</h1><p>p</p>"
        var editor = editor("Foo")
        #expect(paste([.html: html, .string: "T p"], into: editor))
        #expect(editor.string == "Foo\n\n# T\n\np\n")
        editor = self.editor("A\n\nB", selection: NSRange(location: 3, length: 0))
        #expect(paste([.html: html, .string: "T p"], into: editor))
        #expect(editor.string == "A\n\n# T\n\np\n\nB")
        editor = self.editor("")
        #expect(paste([.html: html, .string: "T p"], into: editor))
        #expect(editor.string == "# T\n\np\n")
    }

    @Test func usesTheEditingSettingsAndBaseURL() {
        let editor = editor("")
        editor.pasteOptions = .init(listMarker: "+", indent: "\t")
        #expect(paste([.html: #"<ul><li><a href="x.html">a</a><ul><li>b</li></ul></li></ul>"#,
                       .init("org.chromium.source-url"): "https://e.com/d/page.html", .string: "a b"], into: editor))
        #expect(editor.string == "+ [a](https://e.com/d/x.html)\n\t+ b\n")
    }

    /// Plain text, code and code blocks are left to the usual paste.
    @Test func notConverted() throws {
        #expect(!paste([.string: "plain"], into: editor("")))
        #expect(!paste([.html: try #require(try PasteFixture.load("synthetic-vscode").html), .string: "let"],
                       into: editor("")))
        #expect(!paste([.html: "<b>x</b>", .string: "x"], into: editor("```\ncode\n")))
        let off = editor("")
        off.convertsPastedFormatting = false
        #expect(!paste([.html: "<b>x</b>", .string: "x"], into: off))
        #expect(off.string == "")
    }

    /// Services and drops from other apps read through readSelection, as
    /// Paste does; Paste and Match Style reads plain text.
    @Test func readSelectionConverts() {
        let types: [NSPasteboard.PasteboardType: String] = [.html: "<b>x</b>", .string: "x"]
        var editor = editor("")
        var pasteboard = pasteboard(types)
        #expect(editor.readSelection(from: pasteboard))
        #expect(editor.string == "**x**")
        pasteboard.releaseGlobally()

        editor = self.editor("")
        pasteboard = self.pasteboard(types)
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == "**x**")
        pasteboard.releaseGlobally()

        editor = self.editor("")
        editor.pastesPlainText = true
        pasteboard = self.pasteboard(types)
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == "x")
        pasteboard.releaseGlobally()
    }

    /// Formatted text dropped from another app is converted where it's
    /// dropped.
    @Test func dropsConvert() {
        let (scrollView, textView) = EditorTextView.makeScrollableEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { withExtendedLifetime(window) {} }
        window.contentView = scrollView
        let editor = textView as! EditorTextView
        editor.string = "first line\nsecond line"
        editor.pasteOptions = pasteTestOptions
        let pasteboard = pasteboard([.html: "<b>x</b>", .string: "x"])
        defer { pasteboard.releaseGlobally() }
        let drop = Drop(pasteboard, at: editor.convert(NSPoint(x: 2, y: 2), to: nil))
        #expect(editor.draggingEntered(drop) != [])
        #expect(editor.performDragOperation(drop))
        #expect(editor.string == "**x**first line\nsecond line")
    }

    /// After a converted paste, a button offers the plain text instead.
    @Test func plainTextButton() throws {
        let editor = editor("Intro\n\n")
        #expect(paste([.html: "<p><b>bold</b> text</p>", .string: "bold text"], into: editor))
        let button = try #require(editor.plainTextButton)
        #expect(button.superview === editor && !button.isHidden)
        #expect(button.refusesFirstResponder)
        #expect(button.accessibilityLabel() == "Paste as Plain Text")
        // Just below the pasted line.
        let lineRect = editor.layoutManager!.lineFragmentRect(
            forGlyphAt: editor.layoutManager!.glyphIndexForCharacter(at: 8), effectiveRange: nil)
        #expect(button.frame.minY >= lineRect.maxY + editor.textContainerOrigin.y - 1)
        #expect(button.frame.minY <= lineRect.maxY + editor.textContainerOrigin.y + 10)

        button.performClick(nil)
        #expect(editor.string == "Intro\n\nbold text")
        #expect(editor.plainTextButton == nil)
    }

    /// The button is drawn for the editor theme's background, not the
    /// system's appearance, so it shows on dark themes in light mode.
    @Test func plainTextButtonMatchesTheEditorBackground() throws {
        for (background, dark) in [(NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1), true),
                                   (NSColor(srgbRed: 0.99, green: 0.97, blue: 0.9, alpha: 1), false)] {
            let editor = editor("Intro\n\n")
            editor.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            editor.backgroundColor = background
            #expect(paste([.html: "<p><b>bold</b> text</p>", .string: "bold text"], into: editor))
            let button = try #require(editor.plainTextButton)
            let name = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            #expect(name == (dark ? .darkAqua : .aqua))
        }
    }

    /// The whole insertion, blank lines included, becomes the plain text.
    @Test func plainTextReplacesBlockPaddingToo() throws {
        let editor = editor("Foo")
        #expect(paste([.html: "<h1>T</h1><p>p</p>", .string: "T\np"], into: editor))
        #expect(editor.string == "Foo\n\n# T\n\np\n")
        try #require(editor.plainTextButton).performClick(nil)
        #expect(editor.string == "FooT\np")
    }

    /// No button when there's nothing different to offer.
    @Test func noPlainTextButton() {
        var editor = editor("")
        #expect(paste([.html: "<p>same</p>", .string: "same"], into: editor))
        #expect(editor.plainTextButton == nil)
        editor = self.editor("")
        #expect(paste([.html: "<b>no plain text</b>"], into: editor))
        #expect(editor.plainTextButton == nil)
        editor = self.editor("")
        let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        #expect(editor.pasteConverted(from: pasteboard))
        #expect(editor.plainTextButton == nil)
    }

    /// Pastes bold text after "Intro " and returns the editor showing the
    /// plain-text button.
    func editorWithPlainTextButton(_ text: String = "Intro ") throws -> EditorTextView {
        let editor = editor(text)
        #expect(paste([.html: "<b>bold</b>", .string: "bold"], into: editor))
        try #require(editor.plainTextButton != nil)
        return editor
    }

    /// Typing dismisses the button, and the keystroke goes into the text.
    @Test func typingDismissesThePlainTextButton() throws {
        let editor = try editorWithPlainTextButton()
        editor.insertText("!", replacementRange: editor.selectedRange())
        #expect(editor.plainTextButton == nil && editor.pastedPlainText == nil)
        #expect(editor.string == "Intro **bold**!")
    }

    /// Escape dismisses the button.
    @Test func escapeDismissesThePlainTextButton() throws {
        let editor = try editorWithPlainTextButton()
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.plainTextButton == nil)
        #expect(editor.string == "Intro **bold**")
    }

    /// Moving the selection within the pasted text keeps the button; out of
    /// it, dismisses it.
    @Test func selectionOutsideDismissesThePlainTextButton() throws {
        let editor = try editorWithPlainTextButton()
        editor.setSelectedRange(NSRange(location: 8, length: 2))
        #expect(editor.plainTextButton != nil)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.plainTextButton == nil)
    }

    /// Scrolling the pasted text out of view dismisses the button.
    @Test func scrollingAwayDismissesThePlainTextButton() throws {
        let (scrollView, textView) = EditorTextView.makeScrollableEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { withExtendedLifetime(window) {} }
        window.contentView = scrollView
        let editor = textView as! EditorTextView
        editor.pasteOptions = pasteTestOptions
        editor.string = "Intro \n" + String(repeating: "line\n", count: 300)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(paste([.html: "<b>bold</b>", .string: "bold"], into: editor))
        #expect(editor.plainTextButton != nil)
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        editor.scroll(NSPoint(x: 0, y: 5))
        #expect(editor.plainTextButton != nil)
        editor.scroll(NSPoint(x: 0, y: editor.frame.height - 100))
        #expect(editor.plainTextButton == nil, "frame \(editor.frame) visible \(editor.visibleRect) button \(editor.plainTextButton?.frame ?? .zero)")
    }

    /// Another paste, or replacing the text, dismisses the button.
    @Test func otherChangesDismissThePlainTextButton() throws {
        var editor = try editorWithPlainTextButton()
        let pasteboard = pasteboard([.html: "<i>again</i>", .string: "again"])
        defer { pasteboard.releaseGlobally() }
        #expect(editor.pasteConverted(from: pasteboard))
        #expect(editor.pastedPlainText?.text == "again")
        editor = try editorWithPlainTextButton()
        editor.string = "reloaded"
        #expect(editor.plainTextButton == nil)
    }

    /// A click after the pasted text changed some other way does nothing.
    @Test func plainTextButtonChecksThePastedText() throws {
        let editor = try editorWithPlainTextButton()
        let button = try #require(editor.plainTextButton)
        editor.textStorage?.replaceCharacters(in: NSRange(location: 6, length: 2), with: "__")
        button.performClick(nil)
        #expect(editor.string == "Intro __bold**")
    }

    /// Paste as Markdown converts with the setting off.
    @Test func pasteAsMarkdownIgnoresTheSetting() {
        let editor = editor("")
        editor.convertsPastedFormatting = false
        let pasteboard = pasteboard([.html: "<b>x</b>", .string: "x"])
        defer { pasteboard.releaseGlobally() }
        #expect(editor.pasteConverted(from: pasteboard, convertsFormatting: true))
        #expect(editor.string == "**x**")
        #expect(editor.responds(to: #selector(EditorTextView.pasteAsMarkdown(_:))))
    }

    /// Image data is pasted as a data URI, whatever the setting.
    @Test func images() {
        for converts in [true, false] {
            let editor = editor("See ")
            editor.convertsPastedFormatting = converts
            let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            #expect(editor.pasteConverted(from: pasteboard))
            #expect(editor.string == "See ![](data:image/png;base64,iVBORw==)")
        }
    }
}

/// A drop of `draggingPasteboard` at a window location.
@MainActor final class Drop: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    init(_ pasteboard: NSPasteboard, at location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = location
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

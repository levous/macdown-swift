//
//  SwiftMarkdownSpikeTests.swift
//  MacDownKitTests
//
//  Phase 0 of the swift-markdown migration: checks what swift-markdown
//  provides before the new engine is built on it. The answers are recorded
//  in docs/intents/swift-markdown-migration.md ("Decisions").
//

import Markdown
import Testing
import cmark_gfm

@Suite struct SwiftMarkdownSpikeTests {
    @Test func parsesInADetachedTask() async {
        let summary = await Task.detached {
            let document = Document(parsing: "# Title\n\nSome *text*.\n")
            return (document.childCount, document.child(at: 0) is Heading)
        }.value
        #expect(summary.0 == 2)
        #expect(summary.1)
    }

    // MARK: Footnotes

    /// swift-markdown never sets CMARK_OPT_FOOTNOTES and has no footnote node
    /// types (Sources/Markdown/Parser/CommonMarkConverter.swift).
    @Test func footnotesAreNotParsed() {
        let document = Document(parsing: "A note[^1].\n\n[^1]: The note.\n")
        // Both stay literal text in plain paragraphs: no footnote nodes, and
        // the definition isn't taken as a link reference definition.
        #expect(document.childCount == 2)
        #expect(document.children.allSatisfy { $0 is Paragraph })
        var links = 0
        func walk(_ markup: Markup) {
            if markup is Link { links += 1 }
            markup.children.forEach(walk)
        }
        walk(document)
        #expect(links == 0)
        let text = document.children.compactMap { ($0.child(at: 0) as? Text)?.string }
        #expect(text == ["A note[^1].", "[^1]: The note."])
    }

    /// cmark-gfm itself (swift-markdown's dependency) parses footnotes when
    /// asked, with source positions.
    @Test func cmarkGFMParsesFootnotes() {
        let source = "A note[^1].\n\n[^1]: The note.\n"
        let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES | CMARK_OPT_SOURCEPOS)
        defer { cmark_parser_free(parser) }
        cmark_parser_feed(parser, source, source.utf8.count)
        let root = cmark_parser_finish(parser)
        defer { cmark_node_free(root) }
        var footnotes: [(type: cmark_node_type, line: Int32)] = []
        let iterator = cmark_iter_new(root)
        defer { cmark_iter_free(iterator) }
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER else { continue }
            let node = cmark_iter_get_node(iterator)
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_FOOTNOTE_REFERENCE || type == CMARK_NODE_FOOTNOTE_DEFINITION {
                footnotes.append((type, cmark_node_get_start_line(node)))
            }
        }
        #expect(footnotes.map(\.type) == [CMARK_NODE_FOOTNOTE_REFERENCE, CMARK_NODE_FOOTNOTE_DEFINITION])
        #expect(footnotes.map(\.line) == [1, 3])
    }
}

// MARK: Autolinks

extension SwiftMarkdownSpikeTests {
    /// swift-markdown attaches only the table, strikethrough and tasklist
    /// extensions, not GFM's autolink extension, so bare URLs and emails stay
    /// text. CommonMark `<…>` autolinks are always links.
    @Test func bareURLsAreNotLinked() {
        func links(_ source: String) -> [String] {
            var found: [String] = []
            func walk(_ markup: Markup) {
                if let link = markup as? Link { found.append(link.destination ?? "") }
                markup.children.forEach(walk)
            }
            walk(Document(parsing: source))
            return found
        }
        #expect(links("See https://example.org and www.example.org or hello@example.org.\n") == [])
        #expect(links("See <https://example.org> or <hello@example.org>.\n")
                == ["https://example.org", "mailto:hello@example.org"])
    }
}

// MARK: Smart punctuation, highlight, superscript

extension SwiftMarkdownSpikeTests {
    func text(_ source: String, options: ParseOptions = []) -> String {
        var result = ""
        func walk(_ markup: Markup) {
            if let t = markup as? Text { result += t.string }
            markup.children.forEach(walk)
        }
        walk(Document(parsing: source, options: options))
        return result
    }

    /// Smart punctuation is native, and ON by default: cmark's CMARK_OPT_SMART
    /// is set unless `.disableSmartOpts` is passed. Code is never changed.
    @Test func smartPunctuationIsOnByDefault() {
        let source = #""Quotes," 'single,' en -- dash, em --- dash... `"code" --`"#
        #expect(text(source) == "\u{201C}Quotes,\u{201D} \u{2018}single,\u{2019} en \u{2013} dash, em \u{2014} dash\u{2026} ")
        #expect(text(source, options: .disableSmartOpts) == #""Quotes," 'single,' en -- dash, em --- dash... "#)
        var code = ""
        func walk(_ markup: Markup) {
            if let c = markup as? InlineCode { code = c.code }
            markup.children.forEach(walk)
        }
        walk(Document(parsing: source))
        #expect(code == #""code" --"#)
    }

    /// `==highlight==` and `^superscript` aren't native: they stay text.
    @Test func highlightAndSuperscriptAreNotNative() {
        let document = Document(parsing: "==marked== and x^2 and x^(a b)\n",
                                options: .disableSmartOpts)
        let paragraph = document.child(at: 0)
        #expect(paragraph?.childCount == 1)
        #expect(paragraph?.child(at: 0) is Text)
        #expect(text("==marked== and x^2 and x^(a b)\n") == "==marked== and x^2 and x^(a b)")
    }
}

// MARK: Source ranges and concurrency

extension SwiftMarkdownSpikeTests {
    /// Every block node has a source range; columns count UTF-8 bytes, from 1.
    @Test func everyBlockHasASourceRange() {
        let source = """
            # Title

            Text with 😀 *em*.

            > Quote
            > - item
            >   1. nested

            ```swift
            let x = 1
            ```

                indented

            <div>html</div>

            ---

            | a | b |
            |---|---|
            | 1 | 2 |

            - [x] task

            Setext
            ======
            """
        let document = Document(parsing: source)
        var kinds: Set<String> = []
        var missing: [String] = []
        func walk(_ markup: Markup) {
            if markup is BlockMarkup {
                let kind = String(describing: type(of: markup))
                kinds.insert(kind)
                if markup.range == nil { missing.append(kind) }
            }
            markup.children.forEach(walk)
        }
        walk(document)
        #expect(kinds.isSuperset(of: ["Heading", "Paragraph", "BlockQuote", "UnorderedList",
                                      "OrderedList", "ListItem", "CodeBlock", "HTMLBlock",
                                      "ThematicBreak", "Table"]), "\(kinds)")
        #expect(missing.isEmpty, "no range: \(missing)")

        // "Text with 😀 " is 10 + 4 + 1 bytes, so *em* starts at column 16.
        var emphasis: SourceRange?
        func find(_ markup: Markup) {
            if markup is Emphasis { emphasis = markup.range }
            markup.children.forEach(find)
        }
        find(document)
        #expect(emphasis?.lowerBound == SourceLocation(line: 3, column: 16, source: nil))
    }

    // Document is not Sendable: `await Task.detached { Document(parsing: s) }.value`
    // fails to compile ("type 'Document' does not conform to the 'Sendable'
    // protocol"). The model must run the visitors in the detached task and
    // keep only their Sendable results (F6).
}

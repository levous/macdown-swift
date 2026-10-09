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

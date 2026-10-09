//
//  HighlightBenchmarkTests.swift
//  MacDownKitTests
//
//  NFR-1: edit → highlight spans on a 10,000-line document, PEG against the
//  swift-markdown model, with the stages broken down and, for comparison,
//  cmark-gfm used directly. Run optimized, on demand:
//
//    MACDOWN_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
//      --filter HighlightBenchmarkTests
//
//  Results are recorded in docs/intents/swift-markdown-migration.md (F8).
//

import CPegMarkdown
import Foundation
import Markdown
import Testing
import cmark_gfm
import cmark_gfm_extensions
@testable import MacDownKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACDOWN_BENCHMARK"] != nil))
@MainActor struct HighlightBenchmarkTests {
    /// The median of several runs, in milliseconds.
    func median(_ runs: Int = 9, _ body: () -> Void) -> Double {
        body()    // warm up
        let times = (0..<runs).map { _ in
            let start = ContinuousClock.now
            body()
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        return times.sorted()[runs / 2]
    }

    /// cmark-gfm parsed directly, with GFM extensions and source positions,
    /// and every node's type and range collected (what a direct mapper reads).
    func cmarkDirect(_ text: String) -> Int {
        cmark_gfm_core_extensions_ensure_registered()
        let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES)
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        let root = cmark_parser_finish(parser)
        defer { cmark_node_free(root) }
        let iterator = cmark_iter_new(root)
        defer { cmark_iter_free(iterator) }
        var sum = 0
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER else { continue }
            let node = cmark_iter_get_node(iterator)
            sum &+= Int(cmark_node_get_type(node).rawValue) &+ Int(cmark_node_get_start_line(node))
                &+ Int(cmark_node_get_start_column(node)) &+ Int(cmark_node_get_end_line(node))
                &+ Int(cmark_node_get_end_column(node))
        }
        return sum
    }

    @Test func tenThousandLines() {
        let text = Corpus.generated(lines: 10_000)
        let index = LineIndex(text)
        let document = Document(parsing: text, options: .disableSmartOpts)
        let freshInstall = CorpusTests.settings

        let peg = median { _ = HighlightElements.parse(text, extensions: Int32(pmh_EXT_NOTES.rawValue)) }
        let model = median { _ = MarkdownDocumentModel(text, options: .init()) }
        let modelAll = median {
            _ = MarkdownDocumentModel(text, options: .init(math: true, inlineDollar: true,
                                                           highlight: true, superscript: true))
        }
        let parse = median { _ = Document(parsing: text, options: .disableSmartOpts) }
        var nodes = 0
        let walk = median { func w(_ m: Markup) { nodes += 1; m.children.forEach(w) }; w(document) }
        let mapper = median { _ = HighlightMapper.spans(of: document, source: text,
                                                        lineIndex: index, options: .init()) }
        let protectMath = median { _ = ProtectedSource(text, math: true, inlineDollar: true) }
        let direct = median { _ = cmarkDirect(text) }
        let hoedown = median { _ = MarkdownParser.parse(text, settings: freshInstall) }

        print(String(format: """
            BENCHMARK 10k lines (median ms): PEG %.1f | model %.1f, with math and opt-ins %.1f \
            | stages: swift-markdown parse %.1f, tree walk %.1f, mapper %.1f, protection with math %.1f \
            | cmark-gfm direct parse+walk %.1f | hoedown HTML %.1f
            """, peg, model, modelAll, parse, walk, mapper, protectMath, direct, hoedown))

        // NFR-1 (no worse than PEG) can't be met on swift-markdown's tree:
        // its parse alone takes longer than PEG. PRD Open Question 2.
        withKnownIssue("NFR-1 pending PRD Open Question 2") {
            #expect(model <= peg * 1.1, "model \(model) ms vs PEG \(peg) ms")
        }
    }
}

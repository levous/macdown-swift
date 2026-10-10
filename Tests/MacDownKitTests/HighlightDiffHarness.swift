//
//  HighlightDiffHarness.swift
//  MacDownKitTests
//
//  Compares the editor highlighting of two engines over the corpus, span by
//  span for each element type (TR-8). Today both sides are PEG Markdown
//  Highlight, which proves the harness; Phase 2 puts HighlightMapper on the
//  right.
//
//  Run:    swift test --filter HighlightDiffHarnessTests
//  Report: MACDOWN_DIFF_REPORT=/tmp/diff swift test --filter HighlightDiffHarnessTests
//          writes highlight-diff.md there.
//

import CPegMarkdown
import Foundation
import Testing
@testable import MacDownKit

enum HighlightDiff {
    /// Spans as UTF-16 ranges, keyed by PEG element type name ("EMPH", ...).
    typealias Spans = [String: Set<Range<Int>>]
    typealias Engine = @Sendable (String) -> Spans

    static let peg: Engine = { text in
        let elements = HighlightElements.parse(text, extensions: Int32(pmh_EXT_NOTES.rawValue))
        var spans: Spans = [:]
        for (type, list) in elements.spans.enumerated() where !list.isEmpty {
            let name = String(cString: pmh_element_name_from_type(pmh_element_type(UInt32(type))))
            // The editor skips spans that end before they start (PEG reports
            // one for a header inside a block quote), so the harness does too.
            spans[name] = Set(list.filter { $0.end > $0.pos }.map { $0.pos..<$0.end })
        }
        return spans
    }

    /// HighlightMapper, through the document model (fresh-install options).
    static let mapper: Engine = { text in
        let model = MarkdownDocumentModel(text, options: .init())
        var spans: Spans = [:]
        for (type, list) in model.highlights.spans.enumerated() where !list.isEmpty {
            spans[ThemeStyle.elementNames[type]] = Set(list.filter { $0.end > $0.pos }
                .map { $0.pos..<$0.end })
        }
        return spans
    }

    struct Difference: Sendable {
        let document: String
        let type: String
        let onlyLeft: [Range<Int>]
        let onlyRight: [Range<Int>]
    }

    static func compare(_ documents: [Corpus.Document],
                        left: Engine, right: Engine) -> [Difference] {
        var differences: [Difference] = []
        for document in documents {
            let l = left(document.text)
            let r = right(document.text)
            for type in Set(l.keys).union(r.keys).sorted() {
                let a = l[type] ?? [], b = r[type] ?? []
                guard a != b else { continue }
                differences.append(Difference(
                    document: document.name, type: type,
                    onlyLeft: a.subtracting(b).sorted { $0.lowerBound < $1.lowerBound },
                    onlyRight: b.subtracting(a).sorted { $0.lowerBound < $1.lowerBound }))
            }
        }
        return differences
    }

    /// A Markdown report quoting the source of each differing span, written
    /// to $MACDOWN_DIFF_REPORT if it's set.
    static func report(_ differences: [Difference], documents: [Corpus.Document],
                       left: String, right: String, writes: Bool = true) -> String {
        let texts = Dictionary(documents.map { ($0.name, $0.text as NSString) },
                               uniquingKeysWith: { a, _ in a })
        func quote(_ range: Range<Int>, in document: String) -> String {
            guard let text = texts[document], range.upperBound <= text.length else { return "?" }
            let source = text.substring(with: NSRange(location: range.lowerBound,
                                                      length: min(range.count, 60)))
            return "\(range.lowerBound)..<\(range.upperBound) `\(source.replacingOccurrences(of: "\n", with: "⏎"))`"
        }
        var lines = ["# Highlight diff: \(left) vs \(right)", "",
                     "\(documents.count) documents: \(differences.count) element types differ.", ""]
        for difference in differences {
            lines += ["## \(difference.document): \(difference.type)", ""]
            lines += difference.onlyLeft.prefix(20).map { "- only \(left): \(quote($0, in: difference.document))" }
            lines += difference.onlyRight.prefix(20).map { "- only \(right): \(quote($0, in: difference.document))" }
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        if writes, let directory = ProcessInfo.processInfo.environment["MACDOWN_DIFF_REPORT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? text.write(to: url.appending(path: "highlight-diff.md"), atomically: true, encoding: .utf8)
        }
        return text
    }
}

@Suite struct HighlightDiffHarnessTests {
    /// Proves the harness: PEG against itself has no differences, and an
    /// engine that drops a type and shifts another is reported precisely.
    @Test func pegAgainstItself() throws {
        let corpus = try Corpus.all()
        let differences = HighlightDiff.compare(corpus, left: HighlightDiff.peg,
                                                right: HighlightDiff.peg)
        let report = HighlightDiff.report(differences, documents: corpus,
                                          left: "PEG", right: "PEG", writes: false)
        #expect(differences.isEmpty, "\(report)")

        let files = try Corpus.files()
        let altered: HighlightDiff.Engine = { text in
            var spans = HighlightDiff.peg(text)
            spans["EMPH"] = nil
            spans["STRONG"] = Set((spans["STRONG"] ?? []).map { $0.lowerBound..<($0.upperBound + 1) })
            return spans
        }
        let caught = HighlightDiff.compare(files, left: HighlightDiff.peg, right: altered)
        let emphasis = try #require(caught.first { $0.document == "01-inline.md" && $0.type == "EMPH" })
        #expect(!emphasis.onlyLeft.isEmpty && emphasis.onlyRight.isEmpty)
        let strong = try #require(caught.first { $0.document == "01-inline.md" && $0.type == "STRONG" })
        #expect(strong.onlyLeft.count == strong.onlyRight.count)
        let text = HighlightDiff.report(caught, documents: files, left: "PEG",
                                        right: "altered", writes: false)
        #expect(text.contains("## 01-inline.md: EMPH"))
        #expect(text.contains("`*single asterisks*`"))
    }

    /// PEG against HighlightMapper over the corpus, reviewed 2026-10-09:
    /// every remaining difference is one of these, each an intended change.
    /// A difference outside the list fails; the report shows the spans.
    static let reviewed: [String: String] = [
        "01-inline.md EMPH": "CommonMark nesting of ***x*** and ___x___; PEG mis-nested them and took an unclosed *",
        "01-inline.md STRONG": "same: PEG's ***/___ spans ran across lines",
        "02-blocks.md H1": "#Not a header (no space) isn't a header in CommonMark",
        "02-blocks.md H6": "seven hashes is a paragraph in CommonMark",
        "02-blocks.md LIST_BULLET": "a list can interrupt a paragraph in CommonMark",
        "02-blocks.md LIST_ENUMERATOR": "CommonMark's 1) lists",
        "02-blocks.md VERBATIM": "indented code inside a list item",
        "03-blockquotes.md CODE": "a fence in a quote is one CODE span, markers included; PEG split it",
        "05-links-images.md AUTO_LINK_URL": "<…with spaces> is a link destination, not an autolink",
        "05-links-images.md LINK": "shortcut and case-insensitive reference links",
        "05-links-images.md REFERENCE": "a definition with an angle-bracket destination with spaces",
        "07-html.md HTML": "<details>…</summary> is an HTML block in CommonMark",
        "07-html.md HTMLBLOCK": "same",
        "08-footnotes.md LINK": "footnote content is Markdown; PEG didn't parse footnotes",
        "08-footnotes.md NOTE": "footnotes are colored (FR-27); PEG never emitted NOTE",
        "08-footnotes.md STRONG": "footnote content is Markdown; PEG didn't parse footnotes",
        "10-front-matter-invalid.md H2": "invalid front matter is Markdown: text over --- is a setext header",
        "10-front-matter-invalid.md HRULE": "same: the opening ---",
        "14-math.md CODE": "PEG colored math (and $5 and $) as CODE whatever the settings; math is its own type now",
        "14-math.md EMPH": "with math off, * inside $$…$$ is emphasis",
        "help.md AUTO_LINK_URL": "an autolink in a table cell PEG missed",
        "help.md CODE": "PEG's math rule ran from $1600 to the end of the document",
        "help.md EMPH": "same",
        "help.md H2": "same",
        "help.md H3": "same",
        "help.md H4": "same",
        "help.md HTML": "same",
        "help.md HTMLBLOCK": "same",
        "help.md LINK": "same",
        "help.md LIST_BULLET": "same",
        "help.md LIST_ENUMERATOR": "same",
        "help.md NOTE": "footnotes are colored (FR-27)",
        "help.md STRONG": "same as CODE",
        "generated-10k.md NOTE": "footnotes are colored (FR-27)",
    ]

    @Test func pegAgainstMapperReviewed() throws {
        let corpus = try Corpus.all()
        let differences = HighlightDiff.compare(corpus, left: HighlightDiff.peg,
                                                right: HighlightDiff.mapper)
        _ = HighlightDiff.report(differences, documents: corpus, left: "PEG", right: "mapper")
        let found = Set(differences.map { "\($0.document) \($0.type)" })
        let unexpected = differences.filter { Self.reviewed["\($0.document) \($0.type)"] == nil }
        #expect(unexpected.isEmpty, "\(HighlightDiff.report(unexpected, documents: corpus, left: "PEG", right: "mapper", writes: false))")
        // Entries that no longer differ should come off the list.
        #expect(Set(Self.reviewed.keys).subtracting(found).isEmpty)
    }
}

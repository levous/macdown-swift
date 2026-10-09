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
                                          left: "PEG", right: "PEG")
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
}

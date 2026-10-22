//
//  PasteRoundTripTests.swift
//  MacDownKitTests
//
//  Pasting what the preview shows gives back Markdown that renders the
//  same: each corpus document is rendered, converted back with
//  HTMLToMarkdown, rendered again, and the two bodies compared (paste
//  intent, "Testing strategy"). Resources/reviewed-paste-diffs.json has the
//  reviewed differences, each with its reason: rewrites, applied to the
//  original HTML first, for whole kinds of markup Markdown can't hold
//  (footnotes, in-page links), and single hunks for the rest. A new
//  difference fails, and so does a reviewed one that's gone.
//
//  Report: MACDOWN_DIFF_REPORT=/tmp/diff swift test --filter PasteRoundTripTests
//          writes paste-round-trip.md there.
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct PasteRoundTripTests {
    struct Reviewed: Decodable {
        struct Rewrite: Decodable {
            let id: String
            let reason: String
            let find: String
            let replace: String

            func apply(_ html: String) -> String {
                guard let regex = try? NSRegularExpression(pattern: find, options: .dotMatchesLineSeparators)
                else { return html }
                return regex.stringByReplacingMatches(
                    in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: replace)
            }
        }

        struct Hunk: Decodable {
            let document: String
            let original: String
            let roundTrip: String
            let reason: String
        }

        let rewrites: [Rewrite]
        let hunks: [Hunk]

        static func load() throws -> Reviewed {
            let url = Bundle.module.url(forResource: "reviewed-paste-diffs", withExtension: "json",
                                        subdirectory: "Resources")!
            return try JSONDecoder().decode(Reviewed.self, from: Data(contentsOf: url))
        }
    }

    struct Difference {
        let document: String
        let hunk: HTMLDiff.Hunk
    }

    static func render(_ markdown: String) -> String {
        MarkdownDocumentModel(markdown, options: .init()).body
    }

    /// Normalized HTML, without spaces after a line break, which browsers
    /// don't show.
    static func normalize(_ html: String) -> String {
        HTMLDiff.normalize(html).replacingOccurrences(of: "<br> ", with: "<br>")
    }

    /// Every difference between each document's HTML, after the reviewed
    /// rewrites, and its round trip; and the rewrites that changed something.
    static func differences(rewrites: [Reviewed.Rewrite])
        throws -> (differences: [Difference], usedRewrites: Set<String>, report: String) {
        var differences: [Difference] = []
        var used = Set<String>()
        var report = ["# Paste round trip", ""]
        for document in try Corpus.all() {
            let html = render(document.text)
            let markdown = HTMLToMarkdown(options: pasteTestOptions).convert(html)?.markdown ?? ""
            var original = normalize(html)
            for rewrite in rewrites {
                let rewritten = rewrite.apply(original)
                if rewritten != original { used.insert(rewrite.id) }
                original = rewritten
            }
            original = normalize(original)
            let roundTrip = normalize(render(markdown))
            guard original != roundTrip else { continue }
            let hunks = HTMLDiff.hunks(original, roundTrip)
            differences += hunks.map { Difference(document: document.name, hunk: $0) }
            report += ["## \(document.name)", ""]
            report += hunks.map { "- original: `\($0.left.prefix(200))`\n  round trip: `\($0.right.prefix(200))`" }
            report += ["", "```markdown", markdown, "```", ""]
        }
        return (differences, used, report.joined(separator: "\n"))
    }

    @Test func corpusRoundTripsAsReviewed() throws {
        let reviewed = try Reviewed.load()
        let (differences, used, report) = try Self.differences(rewrites: reviewed.rewrites)
        if let directory = ProcessInfo.processInfo.environment["MACDOWN_DIFF_REPORT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try report.write(to: url.appending(path: "paste-round-trip.md"), atomically: true, encoding: .utf8)
        }
        func key(_ document: String, _ original: String, _ roundTrip: String) -> String {
            document + "\u{1}" + original + "\u{1}" + roundTrip
        }
        let reviewedKeys = Set(reviewed.hunks.map { key($0.document, $0.original, $0.roundTrip) })
        var found = Set<String>()
        for difference in differences {
            let k = key(difference.document, difference.hunk.left, difference.hunk.right)
            found.insert(k)
            #expect(reviewedKeys.contains(k),
                    "unreviewed: \(difference.document) original \(difference.hunk.left.debugDescription) round trip \(difference.hunk.right.debugDescription)")
        }
        #expect(reviewedKeys.subtracting(found).isEmpty, "reviewed differences that are gone; remove them")
        #expect(Set(reviewed.rewrites.map(\.id)).subtracting(used).isEmpty, "rewrites that match nothing; remove them")
        #expect(reviewed.hunks.allSatisfy { !$0.reason.isEmpty } && reviewed.rewrites.allSatisfy { !$0.reason.isEmpty })
    }
}

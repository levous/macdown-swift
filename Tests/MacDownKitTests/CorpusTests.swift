//
//  CorpusTests.swift
//  MacDownKitTests
//
//  The migration corpus (TR-9): purpose-written Markdown in
//  Resources/Corpus, one file per feature area with its edge cases, plus the
//  bundled help.md and a generated 10k-line document. The HTML and
//  highlight-span diff harnesses run over every document here. Never add
//  real user documents or other docs.
//

import Foundation
import Testing
@testable import MacDownKit

enum Corpus {
    struct Document: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        /// The folder relative image paths resolve against, if any.
        let baseURL: URL?

        var testDescription: String { name }
    }

    static var directory: URL {
        Bundle.module.url(forResource: "Corpus", withExtension: nil,
                          subdirectory: "Resources")!
    }

    /// The corpus files, in name order.
    static func files() throws -> [Document] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map {
            Document(name: $0.lastPathComponent,
                     text: try String(contentsOf: $0, encoding: .utf8),
                     baseURL: directory)
        }
    }

    /// Every corpus document: the files, help.md and the generated one.
    static func all() throws -> [Document] {
        try files() + [
            Document(name: "help.md", text: try HelpDocument.text(), baseURL: nil),
            Document(name: "generated-10k.md", text: generated(lines: 10_000), baseURL: nil),
        ]
    }

    /// A long document cycling through the common block types, for
    /// performance checks (NFR-1). Deterministic, exactly `lines` lines.
    static func generated(lines: Int) -> String {
        let blocks = [
            ["## Section %d", ""],
            ["Paragraph %d with *emphasis*, **strong**, `code` and a [link](https://example.org/%d).",
             "It continues on a second line with ~~strikethrough~~.", ""],
            ["- item %d", "- [x] task %d", "  - nested %d", ""],
            ["1. first %d", "2. second %d", ""],
            ["> Quote %d", "> continues", ""],
            ["```swift", "let value%d = %d", "```", ""],
            ["| a | b |", "|---|---|", "| %d | %d |", ""],
            ["A footnote[^n%d].", "", "[^n%d]: Note %d.", ""],
        ]
        var result: [String] = ["# Generated document", ""]
        var n = 0
        while result.count < lines {
            for line in blocks[n % blocks.count] {
                result.append(line.replacingOccurrences(of: "%d", with: String(n)))
            }
            n += 1
        }
        return result.prefix(lines).joined(separator: "\n") + "\n"
    }
}

@MainActor @Suite struct CorpusTests {
    /// Fresh-install settings, independent of `Preferences.shared`, which
    /// the live suites change.
    static let settings: ParseSettings = {
        let suite = "MacDownCorpusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return Preferences(defaults: defaults).renderSettings.parse
    }()

    func render(_ text: String) -> String {
        MarkdownParser.parse(text, settings: Self.settings).body
    }

    @Test func coversEveryArea() throws {
        let names = try Corpus.files().map(\.name)
        #expect(names.count == 19)
        #expect(names.first == "01-inline.md")
        #expect(names.last == "19-images.md")
    }

    @Test(arguments: try Corpus.all())
    func everyDocumentParsesWithBothEngines(_ document: Corpus.Document) {
        #expect(!render(document.text).isEmpty)
        #expect(CMarkTree(document.text).withRoot { !$0.children.isEmpty })
    }

    @Test func generatedDocumentHasExactlyTheRequestedLines() {
        let text = Corpus.generated(lines: 10_000)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 10_001)
        #expect(text == Corpus.generated(lines: 10_000))    // deterministic
        let html = render(text)
        #expect(html.contains("<table>") && html.contains(#"<div class="footnotes">"#))
    }

    @Test func frontMatterCases() throws {
        let files = Dictionary(uniqueKeysWithValues: try Corpus.files().map { ($0.name, $0.text) })
        let valid = render(try #require(files["09-front-matter.md"]))
        #expect(valid.hasPrefix("<table>") && valid.contains("Front matter"))
        let invalid = render(try #require(files["10-front-matter-invalid.md"]))
        #expect(!invalid.hasPrefix("<table>"))
        let rule = render(try #require(files["11-leading-rule.md"]))
        #expect(rule.hasPrefix("<hr>"))
    }

    @Test func crlfDocumentKeepsItsLineEndings() throws {
        let crlf = try #require(try Corpus.files().first { $0.name == "18-crlf.md" })
        #expect(crlf.text.contains("\r\n"))
        #expect(!crlf.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func imagesExist() throws {
        let images = try #require(try Corpus.files().first { $0.name == "19-images.md" })
        let paths = images.text.matches(of: /\]\((images\/[^)]+)\)/).map { String($0.1) }
        #expect(paths.count == 12)
        for path in Set(paths) {
            #expect(FileManager.default.fileExists(
                atPath: Corpus.directory.appending(path: path).path), "\(path)")
        }
    }
}

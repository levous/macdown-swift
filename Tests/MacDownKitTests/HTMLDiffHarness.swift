//
//  HTMLDiffHarness.swift
//  MacDownKitTests
//
//  Compares the body HTML of two Markdown engines over the corpus and a
//  matrix of settings (TR-8). Today both sides are hoedown, which proves the
//  harness; Phase 3 puts swift-markdown's HTMLRenderer on the right.
//
//  Run:    swift test --filter HTMLDiffHarnessTests
//  Report: MACDOWN_DIFF_REPORT=/tmp/diff swift test --filter HTMLDiffHarnessTests
//          writes html-diff.md there, one section per differing document.
//

import Foundation
import Testing
@testable import MacDownKit

enum HTMLDiff {
    typealias Engine = @Sendable (String, ParseSettings) -> String

    static let hoedown: Engine = { MarkdownParser.parse($0, settings: $1).body }

    /// The cmark-gfm renderer, through the document model.
    static let cmark: Engine = { text, settings in
        MarkdownDocumentModel(text, options: .init(settings)).body
    }

    /// The settings each document is rendered with: the always-on standard
    /// set, each opt-in feature on its own, and everything on.
    @MainActor static func matrix() -> [(name: String, settings: ParseSettings)] {
        let optIns: [(String, (Preferences) -> Void)] = [
            ("highlight", { $0.extensionHighlight = true }),
            ("superscript", { $0.extensionSuperscript = true }),
            ("autolink", { $0.extensionAutolink = true }),
            ("smart punctuation", { $0.extensionSmartyPants = true }),
            ("math", { $0.htmlMathJax = true; $0.htmlMathJaxInlineDollar = true }),
            ("toc", { $0.htmlRendersTOC = true }),
            ("hard wrap", { $0.htmlHardWrap = true }),
        ]
        func settings(_ configure: (Preferences) -> Void) -> ParseSettings {
            let suite = "MacDownDiffHarness-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = Preferences(defaults: defaults)
            // Every opt-in off, whatever the fresh-install defaults are.
            preferences.extensionHighlight = false
            preferences.extensionSuperscript = false
            preferences.extensionAutolink = false
            preferences.extensionSmartyPants = false
            preferences.htmlMathJax = false
            preferences.htmlMathJaxInlineDollar = false
            preferences.htmlRendersTOC = false
            preferences.htmlHardWrap = false
            configure(preferences)
            return preferences.renderSettings.parse
        }
        return [("standard", settings { _ in })]
            + optIns.map { name, configure in (name, settings(configure)) }
            + [("all on", settings { p in optIns.forEach { $0.1(p) } })]
    }

    /// HTML with insignificant differences removed: attributes sorted within
    /// each tag, whitespace between tags dropped, other runs collapsed.
    /// A single scan: this runs over every document in every setting.
    static func normalize(_ html: String) -> String {
        normalizeTags(decodeEntities(html))
    }

    /// Entities decoded to characters, so `&copy;` (hoedown passes it
    /// through) and `©` (cmark decodes it) compare equal. `&lt; &gt; &amp;
    /// &quot;` stay: decoding them would change the markup.
    static func decodeEntities(_ html: String) -> String {
        guard html.contains("&") else { return html }
        var result = ""
        var rest = Substring(html)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[amp...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let name = String(after[after.index(after: amp)..<semicolon])
                if !["lt", "gt", "amp", "quot"].contains(name),
                   let decoded = Self.decode(name) {
                    result += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after.dropFirst()
        }
        return result + rest
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        let named = ["nbsp": "\u{A0}", "copy": "©", "reg": "®", "trade": "™", "hellip": "…",
                     "mdash": "—", "ndash": "–", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
                     "rsquo": "’", "laquo": "«", "raquo": "»", "middot": "·", "times": "×",
                     "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "sect": "§",
                     "para": "¶", "bull": "•", "apos": "'"]
        return named[name]
    }

    static func normalizeTags(_ html: String) -> String {
        var output = String.UnicodeScalarView()
        var text = String.UnicodeScalarView()    // since the last tag
        var hasContent = false
        func flushText() {
            // Whitespace alone between two tags is dropped.
            if hasContent { output.append(contentsOf: text) }
            text.removeAll(keepingCapacity: true)
            hasContent = false
        }
        var scalars = html.unicodeScalars[...]
        while let scalar = scalars.first {
            if scalar == "<", let close = scalars.firstIndex(of: ">") {
                flushText()
                output.append(contentsOf: normalizeTag(String(String.UnicodeScalarView(scalars[...close]))).unicodeScalars)
                scalars = scalars[scalars.index(after: close)...]
                continue
            }
            scalars = scalars.dropFirst()
            if scalar.properties.isWhitespace {
                if text.last != " " { text.append(" ") }    // collapse runs
            } else {
                text.append(scalar)
                hasContent = true
            }
        }
        flushText()
        return String(output).trimmingCharacters(in: .whitespaces)
    }

    /// `<name b="2" a='1'>` → `<name a="1" b="2">`. Comments, doctypes and
    /// closing tags are kept as they are.
    private static func normalizeTag(_ tag: String) -> String {
        var chars = Array(tag.unicodeScalars)
        guard chars.count > 2, chars[1].properties.isAlphabetic else { return tag }
        let selfClosing = tag.hasSuffix("/>")
        chars.removeLast(selfClosing ? 2 : 1)
        var index = 1
        func read(while condition: (Unicode.Scalar) -> Bool) -> String {
            var result = String.UnicodeScalarView()
            while index < chars.count, condition(chars[index]) {
                result.append(chars[index]); index += 1
            }
            return String(result)
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
        let name = read { !isSpace($0) && $0 != "/" }
        var attributes: [String] = []
        while true {
            _ = read { isSpace($0) || $0 == "/" }
            guard index < chars.count else { break }
            let key = read { !isSpace($0) && $0 != "=" && $0 != "/" }
            _ = read(while: isSpace)
            guard index < chars.count, chars[index] == "=" else {
                attributes.append(key); continue
            }
            index += 1
            _ = read(while: isSpace)
            var value: String
            if index < chars.count, chars[index] == "\"" || chars[index] == "'" {
                let quote = chars[index]; index += 1
                value = read { $0 != quote }
                index += 1
            } else {
                value = read { !isSpace($0) }
            }
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            attributes.append("\(key)=\"\(value)\"")
        }
        return "<" + ([name] + attributes.sorted()).joined(separator: " ")
            + (selfClosing ? " />" : ">")
    }

    /// An intended difference between hoedown and the new engine, listed
    /// once in Resources/expected-html-diffs.json rather than per document.
    /// A hunk is expected when the entries' `find` → `replace` rewrites,
    /// applied in turn, make hoedown's side into the other side (neighboring
    /// differences can share a hunk).
    struct ExpectedDifference: Decodable, Sendable {
        let id: String
        let reason: String
        let find: String
        let replace: String

        func rewrite(_ html: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: find) else { return html }
            return regex.stringByReplacingMatches(
                in: html, range: NSRange(location: 0, length: (html as NSString).length),
                withTemplate: replace)
        }
    }

    /// The ids of the entries that explain a hunk, or nil if they don't.
    static func explanation(of hunk: Hunk, by entries: [ExpectedDifference]) -> [String]? {
        var html = hunk.left
        var ids: [String] = []
        for entry in entries {
            let rewritten = entry.rewrite(html)
            if rewritten != html { ids.append(entry.id); html = rewritten }
        }
        return !ids.isEmpty && html == hunk.right ? ids : nil
    }

    static func expectedDifferences() throws -> [ExpectedDifference] {
        let url = Bundle.module.url(forResource: "expected-html-diffs", withExtension: "json",
                                    subdirectory: "Resources")!
        return try JSONDecoder().decode([ExpectedDifference].self, from: Data(contentsOf: url))
    }

    /// A run of differing tokens: what the left engine has there, and what
    /// the right one has.
    struct Hunk: Sendable, Equatable {
        let left: String
        let right: String
    }

    /// Tags and words (with their spacing) of normalized HTML.
    static func tokens(_ html: String) -> [Substring] {
        html.matches(of: /<[^>]*>|[^<\s]+|\s/).map(\.output)
    }

    /// The differing token runs between two normalized HTML strings.
    static func hunks(_ left: String, _ right: String) -> [Hunk] {
        let a = tokens(left), b = tokens(right)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Tokens that aren't removed (left) or inserted (right) match in
        // order, so walk both and collect each run of changes.
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && !removed.contains(i) && j < b.count && !inserted.contains(j) {
                i += 1; j += 1; continue
            }
            var l = "", r = ""
            while i < a.count && removed.contains(i) { l += a[i]; i += 1 }
            while j < b.count && inserted.contains(j) { r += b[j]; j += 1 }
            hunks.append(Hunk(left: l, right: r))
        }
        return hunks
    }

    struct Difference: Sendable {
        let document: String
        let setting: String
        /// Hunks no expected difference explains.
        let hunks: [Hunk]
    }

    struct Comparison: Sendable {
        var differences: [Difference] = []
        /// How often each expected difference occurred.
        var expected: [String: Int] = [:]
    }

    /// Renders every document with every setting on both engines, and
    /// returns the differences the expected list doesn't explain.
    @MainActor static func compare(_ documents: [Corpus.Document], left: Engine, right: Engine,
                                   expected: [ExpectedDifference] = []) -> Comparison {
        var comparison = Comparison()
        for (name, settings) in matrix() {
            for document in documents {
                let l = normalize(left(document.text, settings))
                let r = normalize(right(document.text, settings))
                guard l != r else { continue }
                var unexplained: [Hunk] = []
                for hunk in hunks(l, r) {
                    if let ids = explanation(of: hunk, by: expected) {
                        for id in ids { comparison.expected[id, default: 0] += 1 }
                    } else {
                        unexplained.append(hunk)
                    }
                }
                if !unexplained.isEmpty {
                    comparison.differences.append(Difference(
                        document: document.name, setting: name, hunks: unexplained))
                }
            }
        }
        return comparison
    }

    /// A Markdown report, written to $MACDOWN_DIFF_REPORT if it's set.
    static func report(_ comparison: Comparison, expected: [ExpectedDifference] = [],
                       left: String, right: String,
                       documents: Int, settings: Int, writes: Bool = true) -> String {
        let differences = comparison.differences
        var lines = ["# HTML diff: \(left) vs \(right)", "",
                     "\(documents) documents × \(settings) settings: \(differences.count) with unexpected differences.", ""]
        if !expected.isEmpty {
            lines += ["## Expected differences", ""]
            lines += expected.map { "- **\($0.id)** (\(comparison.expected[$0.id] ?? 0)×): \($0.reason)" }
            lines.append("")
        }
        for difference in differences {
            lines += ["## \(difference.document) (\(difference.setting))", ""]
            for hunk in difference.hunks.prefix(20) {
                lines += ["- \(left): `\(hunk.left.prefix(200))`", "  \(right): `\(hunk.right.prefix(200))`"]
            }
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        if writes, let directory = ProcessInfo.processInfo.environment["MACDOWN_DIFF_REPORT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? text.write(to: url.appending(path: "html-diff.md"), atomically: true, encoding: .utf8)
        }
        return text
    }
}

// Inside the serialized live group: the harness renders the corpus many
// times, and run alongside the WKWebView suites it starves their timeouts.
extension LiveDocumentTests {
@MainActor @Suite struct HTMLDiffHarnessTests {
    @Test func normalizerIgnoresAttributeOrderAndWhitespace() {
        let a = #"<p>Hi</p>   <img src="a.png" alt='x'/>"# + "\n<div class=\"c\" id=\"d\">\n  text\n</div>"
        let b = #"<p>Hi</p><img alt="x" src="a.png" />"# + #"<div id="d" class="c"> text </div>"#
        #expect(HTMLDiff.normalize(a) == HTMLDiff.normalize(b))
        #expect(HTMLDiff.normalize("<input checked disabled type=checkbox>")
                == HTMLDiff.normalize("<input type=checkbox disabled checked>"))
        // Real differences survive.
        #expect(HTMLDiff.normalize("<p>Hi</p>") != HTMLDiff.normalize("<p>Hi!</p>"))
        #expect(HTMLDiff.normalize(#"<a href="x">"#) != HTMLDiff.normalize(#"<a href="y">"#))
        #expect(HTMLDiff.normalize("<em>x</em>") != HTMLDiff.normalize("<i>x</i>"))
    }

    @Test func matrixCoversEveryOptIn() {
        let matrix = HTMLDiff.matrix()
        #expect(matrix.map(\.name) == ["standard", "highlight", "superscript", "autolink",
                                       "smart punctuation", "math", "toc", "hard wrap", "all on"])
        // Each setting renders differently from the standard set somewhere.
        let corpus = (try? Corpus.all()) ?? []
        let standard = matrix[0].settings
        for (name, settings) in matrix.dropFirst() {
            let changes = corpus.contains {
                HTMLDiff.hoedown($0.text, settings) != HTMLDiff.hoedown($0.text, standard)
            }
            #expect(changes, "\(name) changes nothing")
        }
    }

    /// Proves the harness end to end: an engine against itself has no
    /// differences, and a deliberately different engine is reported.
    @Test func hoedownAgainstItself() throws {
        let corpus = try Corpus.all()
        let expected = try HTMLDiff.expectedDifferences()
        let comparison = HTMLDiff.compare(corpus, left: HTMLDiff.hoedown,
                                          right: HTMLDiff.hoedown, expected: expected)
        let report = HTMLDiff.report(comparison, expected: expected, left: "hoedown",
                                     right: "hoedown", documents: corpus.count,
                                     settings: HTMLDiff.matrix().count)
        #expect(comparison.differences.isEmpty && comparison.expected.isEmpty, "\(report)")

        let files = try Corpus.files()
        let altered: HTMLDiff.Engine = {
            HTMLDiff.hoedown($0, $1).replacingOccurrences(of: "<strong>", with: "<b>")
        }
        let caught = HTMLDiff.compare(files, left: HTMLDiff.hoedown, right: altered)
        #expect(caught.differences.contains { $0.document == "01-inline.md" && $0.setting == "standard" })
        #expect(HTMLDiff.report(caught, left: "hoedown", right: "altered",
                                documents: files.count, settings: 9, writes: false)
                    .contains("## 01-inline.md (standard)"))
    }

    @Test func hunksAreTheDifferingRuns() {
        let hunks = HTMLDiff.hunks("<p>one two three</p><p>four</p>",
                                   "<p>one 2 three</p><p>four five</p>")
        #expect(hunks == [HTMLDiff.Hunk(left: "two", right: "2"),
                          HTMLDiff.Hunk(left: "", right: " five")])
    }

    /// An engine that leaves intra-word underscores alone, as CommonMark
    /// does, differs from hoedown only by expected differences, each listed
    /// once with its count.
    @Test func expectedDifferencesAreListedOnce() throws {
        let expected = try HTMLDiff.expectedDifferences()
        #expect(Set(expected.map(\.id)).count == expected.count)
        let commonMark: HTMLDiff.Engine = { text, settings in
            HTMLDiff.hoedown(text, settings)
                .replacing(/snake<em>case<\/em>name/, with: "snake_case_name")
                .replacing(/foo<strong>bar<\/strong>baz/, with: "foo__bar__baz")
        }
        let files = try Corpus.files()
        let comparison = HTMLDiff.compare(files, left: HTMLDiff.hoedown, right: commonMark,
                                          expected: expected)
        #expect(comparison.differences.isEmpty)
        #expect(comparison.expected["intraword-underscore-emphasis", default: 0] > 0)
        #expect(comparison.expected["intraword-underscore-strong", default: 0] > 0)
        let report = HTMLDiff.report(comparison, expected: expected, left: "hoedown",
                                     right: "CommonMark", documents: files.count,
                                     settings: 9, writes: false)
        #expect(report.contains("0 with unexpected differences"))
        #expect(report.components(separatedBy: "intraword-underscore-emphasis").count == 2)
        // Without the list, the same differences are unexpected.
        #expect(!HTMLDiff.compare(files, left: HTMLDiff.hoedown, right: commonMark)
            .differences.isEmpty)
    }

    /// hoedown against the cmark-gfm renderer: a report only, until the
    /// Phase 3 review makes it an assertion.
    @Test func hoedownAgainstCmarkReport() throws {
        let corpus = try Corpus.all()
        let expected = try HTMLDiff.expectedDifferences()
        let comparison = HTMLDiff.compare(corpus, left: HTMLDiff.hoedown, right: HTMLDiff.cmark,
                                          expected: expected)
        let report = HTMLDiff.report(comparison, expected: expected, left: "hoedown",
                                     right: "cmark", documents: corpus.count,
                                     settings: HTMLDiff.matrix().count, writes: false)
        if let directory = ProcessInfo.processInfo.environment["MACDOWN_DIFF_REPORT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try report.write(to: url.appending(path: "html-diff-cmark.md"), atomically: true, encoding: .utf8)
        }
        #expect(!report.isEmpty)
    }

    @Test func entitiesDecodeForComparison() {
        #expect(HTMLDiff.normalize("<p>&copy; &#169; &#xA9; ©</p>") == "<p>© © © ©</p>")
        #expect(HTMLDiff.normalize("<p>&lt;b&gt; &amp; &quot;</p>") == "<p>&lt;b&gt; &amp; &quot;</p>")
    }
}
}

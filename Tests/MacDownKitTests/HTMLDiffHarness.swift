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

    struct Difference: Sendable {
        let document: String
        let setting: String
        let left: String
        let right: String

        /// The first differing position, with some context either side.
        var excerpt: (left: String, right: String) {
            let common = zip(left, right).prefix { $0 == $1 }.count
            func around(_ s: String) -> String {
                let start = s.index(s.startIndex, offsetBy: max(0, common - 80))
                let end = s.index(start, offsetBy: min(240, s.distance(from: start, to: s.endIndex)))
                return String(s[start..<end])
            }
            return (around(left), around(right))
        }
    }

    /// Renders every document with every setting on both engines, and
    /// returns the documents whose normalized HTML differs.
    @MainActor static func compare(_ documents: [Corpus.Document],
                                   left: Engine, right: Engine) -> [Difference] {
        var differences: [Difference] = []
        for (name, settings) in matrix() {
            for document in documents {
                let l = normalize(left(document.text, settings))
                let r = normalize(right(document.text, settings))
                if l != r {
                    differences.append(Difference(document: document.name, setting: name,
                                                  left: l, right: r))
                }
            }
        }
        return differences
    }

    /// A Markdown report, written to $MACDOWN_DIFF_REPORT if it's set.
    static func report(_ differences: [Difference], left: String, right: String,
                       documents: Int, settings: Int, writes: Bool = true) -> String {
        var lines = ["# HTML diff: \(left) vs \(right)", "",
                     "\(documents) documents × \(settings) settings: \(differences.count) differ.", ""]
        for difference in differences {
            let excerpt = difference.excerpt
            lines += ["## \(difference.document) (\(difference.setting))", "",
                      "\(left):", "", "```html", excerpt.left, "```", "",
                      "\(right):", "", "```html", excerpt.right, "```", ""]
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
        let differences = HTMLDiff.compare(corpus, left: HTMLDiff.hoedown, right: HTMLDiff.hoedown)
        let report = HTMLDiff.report(differences, left: "hoedown", right: "hoedown",
                                     documents: corpus.count, settings: HTMLDiff.matrix().count)
        #expect(differences.isEmpty, "\(report)")

        let altered: HTMLDiff.Engine = {
            HTMLDiff.hoedown($0, $1).replacingOccurrences(of: "<strong>", with: "<b>")
        }
        let files = try Corpus.files()
        let caught = HTMLDiff.compare(files, left: HTMLDiff.hoedown, right: altered)
        #expect(caught.contains { $0.document == "01-inline.md" && $0.setting == "standard" })
        #expect(HTMLDiff.report(caught, left: "hoedown", right: "altered",
                                documents: files.count, settings: 9, writes: false)
                    .contains("## 01-inline.md (standard)"))
    }
}
}

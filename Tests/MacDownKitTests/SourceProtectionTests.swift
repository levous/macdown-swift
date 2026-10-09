//
//  SourceProtectionTests.swift
//  MacDownKitTests
//

import Foundation
import Markdown
import Testing
@testable import MacDownKit

@Suite struct SourceProtectionTests {
    func protect(_ source: String, math: Bool = true, inlineDollar: Bool = true) -> ProtectedSource {
        ProtectedSource(source, math: math, inlineDollar: inlineDollar)
    }

    /// The math the pass found, as source text.
    func math(_ source: String, math enabled: Bool = true, inlineDollar: Bool = true) -> [String] {
        let bytes = Array(source.utf8)
        return protect(source, math: enabled, inlineDollar: inlineDollar).math.map {
            String(decoding: bytes[$0], as: UTF8.self)
        }
    }

    /// Same length, same bytes outside protected ranges, line breaks kept.
    func expectOffsetsUnchanged(_ result: ProtectedSource,
                                sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let original = Array(result.source.utf8), protected = Array(result.protected.utf8)
        #expect(original.count == protected.count, sourceLocation: sourceLocation)
        guard original.count == protected.count else { return }
        let ranges = result.math + (result.frontMatter.map { [$0.range] } ?? [])
        for i in original.indices {
            let inside = ranges.contains { $0.contains(i) }
            if !inside || original[i] == UInt8(ascii: "\n") || original[i] == UInt8(ascii: "\r") {
                #expect(protected[i] == original[i], "byte \(i)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func findsEachDelimiter() {
        let source = #"Inline $a_1$, display $$b_2$$, \\(c_3\\) and \\[d_4\\]."#
        #expect(math(source) == ["$a_1$", "$$b_2$$", #"\\(c_3\\)"#, #"\\[d_4\\]"#])
        expectOffsetsUnchanged(protect(source))
    }

    @Test func inlineDollarsOnlyWithTheirSetting() {
        #expect(math("$a$ and $$b$$", inlineDollar: false) == ["$$b$$"])
        #expect(math("$a$ and $$b$$ and \\\\(c\\\\)", math: false).isEmpty)
    }

    @Test func notMath() {
        #expect(math("It costs $5 and $10, or $1600.").isEmpty)
        #expect(math(#"Escaped \$5 and \$x\$ stay literal."#).isEmpty)
        #expect(math("Code `$x_1$` and `$$y$$` isn't math.").isEmpty)
        #expect(math("```\n$$ not math $$\n```\n\n    $$ indented code $$\n").isEmpty)
        #expect(math("<div>$$ raw html $$</div>\n").isEmpty)
        #expect(math(#"A single \(paren\) is an escape, not math."#).isEmpty)
        #expect(math("$ spaced $ and $no closing").isEmpty)
        #expect(math("$a\n\nb$ and $$c\n\nd$$").isEmpty)    // never across a blank line
    }

    @Test func mathSurvivesEmphasis() {
        let source = "*a* $x_1 * y_2$ and $$a_b * c_d$$ *b* \\\\(e_f\\\\) _c_\n"
        let result = protect(source)
        expectOffsetsUnchanged(result)
        var emphasis = 0
        func walk(_ markup: Markup) {
            if markup is Emphasis { emphasis += 1 }
            markup.children.forEach(walk)
        }
        walk(Document(parsing: result.protected))
        #expect(emphasis == 3)    // *a*, *b*, _c_; nothing inside the math
        #expect(result.math.count == 3)
    }

    @Test func multilineAndMultibyteMath() {
        let source = "Text\n\n$$\n\\int_0^1 é😀 \\, dx\n$$\n\nMore $α_β$ text.\n"
        let result = protect(source)
        expectOffsetsUnchanged(result)
        #expect(math(source) == ["$$\n\\int_0^1 é😀 \\, dx\n$$", "$α_β$"])
        #expect(LineIndex(result.protected).lineCount == LineIndex(source).lineCount)
    }

    @Test func validFrontMatterIsBlanked() throws {
        let source = "---\ntitle: Notes\ntags: [a, b]\n---\n\n# Body\n"
        let result = protect(source)
        expectOffsetsUnchanged(result)
        let frontMatter = try #require(result.frontMatter)
        #expect(frontMatter.range == 0..<33)
        #expect(frontMatter.object["title"] == .string("Notes"))
        // Only blank lines are left for the parser: the body is the first block.
        let document = Document(parsing: result.protected)
        #expect(document.childCount == 1)
        #expect((document.child(at: 0) as? Heading)?.range?.lowerBound.line == 6)
    }

    @Test func otherLeadingDashesAreUntouched() {
        for source in ["---\ntitle: \"unterminated\n---\n\nBody\n",
                       "---\n\n# Starts with a rule\n\n---\n"] {
            let result = protect(source)
            #expect(result.frontMatter == nil)
            #expect(result.protected == source)
        }
    }

    @Test(arguments: try Corpus.all())
    func corpusOffsetsUnchanged(_ document: Corpus.Document) {
        expectOffsetsUnchanged(protect(document.text))
    }

    @Test func corpusMathDocument() throws {
        let document = try #require(try Corpus.files().first { $0.name == "14-math.md" })
        let found = math(document.text)
        #expect(found.contains("$A^T_S = B$"))
        #expect(found.contains(#"\\[ a_1 + a_2 = b_{12} \\]"#))
        #expect(found.contains(#"\\( e^{i\pi} + 1 = 0 \\)"#))
        #expect(found.contains("$$x_{*} = y_{*}$$"))
        #expect(!found.contains { $0.contains("$5") || $0.contains("$10") || $0.contains("not math") })
    }
}

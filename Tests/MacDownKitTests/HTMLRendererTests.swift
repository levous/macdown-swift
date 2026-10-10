//
//  HTMLRendererTests.swift
//  MacDownKitTests
//
//  The cmark-gfm renderer writes hoedown's markup (TR-5).
//

import CHoedown
import Foundation
import Testing
@testable import MacDownKit

@Suite struct HTMLEscapingTests {
    static let stress = #"a & b < c > d "e" 'f' /g/ \h [i] {j} |k| ~l `m` ^n é 😀 %20 ?x=1&y='2' #frag"#

    func hoedown(_ text: String, _ escape: (UnsafeMutablePointer<hoedown_buffer>?, UnsafePointer<UInt8>, Int) -> Void) -> String {
        let ob = hoedown_buffer_new(64)
        defer { hoedown_buffer_free(ob) }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { escape(ob, $0.baseAddress!, $0.count) }
        return String(decoding: UnsafeBufferPointer(start: ob!.pointee.data, count: ob!.pointee.size), as: UTF8.self)
    }

    @Test func htmlMatchesHoedown() {
        #expect(HTMLEscaping.html(Self.stress) == hoedown(Self.stress) { hoedown_escape_html($0, $1, $2, 0) })
    }

    @Test func hrefMatchesHoedown() {
        #expect(HTMLEscaping.href(Self.stress) == hoedown(Self.stress) { hoedown_escape_href($0, $1, $2) })
        // Every byte value.
        let all = String(decoding: (1...127).map { UInt8($0) }, as: UTF8.self)
        #expect(HTMLEscaping.href(all) == hoedown(all) { hoedown_escape_href($0, $1, $2) })
    }
}

@MainActor @Suite struct HTMLRendererTests {
    func html(_ text: String, _ options: MarkdownDocumentModel.Options = .init()) -> String {
        MarkdownDocumentModel(text, options: options).body
    }

    /// hoedown's output with fresh-install settings.
    func hoedown(_ text: String) -> String {
        MarkdownParser.parse(text, settings: CorpusTests.settings).body
    }

    /// Where CommonMark and hoedown agree, the output is hoedown's, byte
    /// for byte (TR-5).
    @Test(arguments: [
        "# One\n\nText *em* **strong** `code`.\n\n## Two\n",
        "- a\n- b\n",
        "- a\n\n- b\n",
        "> quote\n>\n> - item\n",
        "- [x] done\n- [ ] open\n",
        "- [x] loose\n\n- [ ] task\n",
        "```js\nlet a = 1;\n```\n",
        "    <b>\n",
        "~~gone~~ and a\nsoft break\n",
        "Hard  \nbreak\n",
        "| a | b |\n|:--|--:|\n| 1 | 2 |\n",
        "| only |\n|---|\n",
        "A[^n] B[^m].\n\n[^m]: Em.\n\n[^n]: En.\n",
        "[a](https://x.org/?a=1&b='2' \"T\") ![alt](i.png \"t\") <https://y.org> <me@z.org> <span>s</span>\n",
        "<div>\nraw\n</div>\n\n---\n",
    ])
    func matchesHoedown(_ text: String) {
        #expect(html(text) == hoedown(text))
    }

    /// Front matter (FR-15): a valid YAML block is a table before the body;
    /// otherwise it's Markdown. Same as hoedown.
    @Test(arguments: ["09-front-matter.md", "11-leading-rule.md"])
    func frontMatter(_ name: String) throws {
        let text = try #require(try Corpus.files().first { $0.name == name }).text
        #expect(HTMLDiff.normalize(html(text)) == HTMLDiff.normalize(hoedown(text)))
    }

    /// Invalid front matter is Markdown; in CommonMark a setext header can
    /// span lines, so both lines are the <h2> (hoedown took only the last).
    @Test func invalidFrontMatter() throws {
        let text = try #require(try Corpus.files().first { $0.name == "10-front-matter-invalid.md" }).text
        let body = html(text)
        #expect(!body.contains("<table>"))
        #expect(body.hasPrefix("<hr>\n\n<h2 id=\"toc_0\">title: &quot;unterminated\ntags: [one, two</h2>"))
    }

    /// [TOC] (FR-12) with the setting on: hoedown's nested lists, the
    /// outer one classed "toc", linking to the toc_N header ids.
    @Test func tableOfContents() throws {
        var settings = CorpusTests.settings
        settings.rendersTOC = true
        for text in [try #require(try Corpus.files().first { $0.name == "13-toc.md" }).text,
                     "## Start\n\n[TOC]\n\n# Higher [link](x) *em*\n\n### Deep\n"] {
            let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
            #expect(cmark.contains("<ul class=\"toc\">"))
            #expect(HTMLDiff.normalize(cmark) == HTMLDiff.normalize(MarkdownParser.parse(text, settings: settings).body))
        }
        #expect(!html("[TOC]\n\n# A\n").contains("class=\"toc\""))    // off by default
    }

    /// Hard wrap (FR-13): with the setting on, a soft break is <br>.
    @Test func hardWrap() {
        var settings = CorpusTests.settings
        settings.rendererFlags |= HOEDOWN_HTML_HARD_WRAP.rawValue
        let text = "one\ntwo\nthree\n"
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark == MarkdownParser.parse(text, settings: settings).body)
        #expect(!html(text).contains("<br>"))
        // Also in tight list items, which hoedown skipped (its rule was in
        // the paragraph renderer).
        #expect(MarkdownDocumentModel("- a\n  b\n", options: .init(settings)).body
                == "<ul>\n<li>a<br>\nb</li>\n</ul>\n")
    }

    /// Math (FR-14): put back in MathJax's delimiters, content escaped, as
    /// hoedown did, untouched by Markdown.
    @Test(arguments: [false, true])
    func math(inlineDollar: Bool) {
        var settings = CorpusTests.settings
        settings.extensionFlags |= HOEDOWN_EXT_MATH.rawValue
        if inlineDollar { settings.extensionFlags |= HOEDOWN_EXT_MATH_EXPLICIT.rawValue }
        for text in [
            "$$\n\\int_0^1 x^2 \\, dx < 1\n$$\n",
            "Inline \\\\( a_1 * b_2 \\\\) and display \\\\[ c_{*} \\\\].\n",
            "In text $$x_1 * y_2$$ here.\n",
            "Dollars $A^T_S = B$ and *emphasis*.\n",
            "# Header $$h_1$$\n\n| $t_1$ |\n|---|\n",
        ] {
            let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
            #expect(cmark == MarkdownParser.parse(text, settings: settings).body, "\(text.debugDescription)")
        }
    }

    /// Autolink (FR-8a): bare URLs and emails only with the setting on;
    /// <url> always.
    @Test func autolinks() {
        let text = "See https://example.org/page?q=1, www.example.org and hello@example.org; <https://x.org>.\n"
        var settings = CorpusTests.settings
        let off = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(off.components(separatedBy: "<a href").count == 2)    // just <https://x.org>
        settings.extensionFlags |= HOEDOWN_EXT_AUTOLINK.rawValue
        let on = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(on == MarkdownParser.parse(text, settings: settings).body)
    }

    /// Smart punctuation (FR-17): curly quotes, dashes and ellipses with
    /// the setting on, never in code. cmark writes the characters where
    /// hoedown wrote entities, so compare with entities decoded.
    @Test func smartPunctuation() {
        let text = "\"Double,\" 'single,' it's, en -- dash, em --- dash... `\"code\" --`\n\n```\n\"block\" --\n```\n"
        var settings = CorpusTests.settings
        #expect(MarkdownDocumentModel(text, options: .init(settings)).body.contains("&quot;Double,&quot;"))
        settings.smartyPants = true
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark.contains("“Double,” ‘single,’ it’s, en – dash, em — dash…"))
        #expect(HTMLDiff.normalize(cmark) == HTMLDiff.normalize(MarkdownParser.parse(text, settings: settings).body))
    }

    /// Highlight and superscript (FR-19, FR-19a): in plain text, with their
    /// settings on.
    @Test func highlightAndSuperscript() {
        let text = "==marked== and == spaced == and x^2, 10^(-6), e^(i pi) and a ^ caret. `==no== x^2`\n"
        var settings = CorpusTests.settings
        #expect(!MarkdownDocumentModel(text, options: .init(settings)).body.contains("<mark>"))
        settings.extensionFlags |= HOEDOWN_EXT_HIGHLIGHT.rawValue | HOEDOWN_EXT_SUPERSCRIPT.rawValue
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark == MarkdownParser.parse(text, settings: settings).body)
    }

    @Test func codeBlockOptions() {
        #expect(html("```swift:x.swift\nlet x\n```\n", .init(lineNumbers: true, blockCodeInformation: true)) ==
            "<div><pre class=\"line-numbers\" data-information=\"x.swift\"><code class=\"language-swift\">let x</code></pre></div>\n")
        let model = MarkdownDocumentModel("```c++\nint x;\n```\n", options: .init())
        #expect(model.languages.contains("cpp") && model.languages.contains("c"))
    }

    /// CommonMark differences, listed in docs/MACDOWN-PORT.md.
    @Test func commonMarkDifferences() {
        #expect(html("3. c\n") == "<ol start=\"3\">\n<li>c</li>\n</ol>\n")    // hoedown dropped the start
        #expect(html("![alt *b*](i.png)\n") == "<p><img src=\"i.png\" alt=\"alt b\"></p>\n")
        // A footnote referenced twice links both times; hoedown left the
        // second as text.
        #expect(html("A[^n] A[^n].\n\n[^n]: En.\n").components(separatedBy: "href=\"#fn1\"").count == 3)
        // GFM task lists: [X] is checked, and the box needs a space after it.
        #expect(html("- [X] capital\n").contains("<input type=\"checkbox\" checked> capital"))
        #expect(html("- [ ]no space\n") == "<ul>\n<li>[ ]no space</li>\n</ul>\n")
    }
}

/// Both engines collect the same Prism languages (FR-10).
@MainActor @Suite struct PrismLanguageTests {
    @Test(arguments: try Corpus.all())
    func sameLanguagesAsHoedown(_ document: Corpus.Document) {
        let hoedown = MarkdownParser.parse(document.text, settings: CorpusTests.settings).languages
        let cmark = MarkdownDocumentModel(document.text, options: .init(CorpusTests.settings)).languages
        #expect(Set(cmark) == Set(hoedown), "\(document.name)")
    }
}

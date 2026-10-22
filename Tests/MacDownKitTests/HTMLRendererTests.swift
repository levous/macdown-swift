//
//  HTMLRendererTests.swift
//  MacDownKitTests
//
//  The cmark-gfm renderer writes hoedown's markup (TR-5), checked against
//  hoedown's recorded output (EngineSnapshots).
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct HTMLEscapingTests {
    static let stress = #"a & b < c > d "e" 'f' /g/ \h [i] {j} |k| ~l `m` ^n é 😀 %20 ?x=1&y='2' #frag"#

    @Test func htmlMatchesHoedown() throws {
        #expect(HTMLEscaping.html(Self.stress) == (try EngineSnapshots.value("escape/html")))
    }

    @Test func hrefMatchesHoedown() throws {
        #expect(HTMLEscaping.href(Self.stress) == (try EngineSnapshots.value("escape/href")))
        // Every byte value.
        let all = String(decoding: (1...127).map { UInt8($0) }, as: UTF8.self)
        #expect(HTMLEscaping.href(all) == (try EngineSnapshots.value("escape/href-ascii")))
    }
}

@MainActor @Suite struct HTMLRendererTests {
    func html(_ text: String, _ options: MarkdownDocumentModel.Options = .init()) -> String {
        MarkdownDocumentModel(text, options: options).body
    }

    /// Where CommonMark and hoedown agree, the output is hoedown's, byte
    /// for byte (TR-5).
    nonisolated static let byteForByte = [
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
    ]

    static let tocTexts = { () throws -> [String] in
        [try #require(try Corpus.files().first { $0.name == "13-toc.md" }).text,
         "## Start\n\n[TOC]\n\n# Higher [link](x) *em*\n\n### Deep\n"]
    }

    static let mathTexts = [
        "$$\n\\int_0^1 x^2 \\, dx < 1\n$$\n",
        "Inline \\\\( a_1 * b_2 \\\\) and display \\\\[ c_{*} \\\\].\n",
        "In text $$x_1 * y_2$$ here.\n",
        "Dollars $A^T_S = B$ and *emphasis*.\n",
        "# Header $$h_1$$\n\n| $t_1$ |\n|---|\n",
    ]

    static let autolinkText = "See https://example.org/page?q=1, www.example.org and hello@example.org; <https://x.org>.\n"
    static let smartText = "\"Double,\" 'single,' it's, en -- dash, em --- dash... `\"code\" --`\n\n```\n\"block\" --\n```\n"
    static let markText = "==marked== and == spaced == and x^2, 10^(-6), e^(i pi) and a ^ caret. `==no== x^2`\n"

    @Test(arguments: byteForByte)
    func matchesHoedown(_ text: String) throws {
        #expect(html(text) == (try EngineSnapshots.value("render/" + text)))
    }

    /// Front matter (FR-15): a valid YAML block is a table before the body;
    /// otherwise it's Markdown. Same as hoedown.
    @Test(arguments: ["09-front-matter.md", "11-leading-rule.md"])
    func frontMatter(_ name: String) throws {
        let text = try #require(try Corpus.files().first { $0.name == name }).text
        #expect(HTMLDiff.normalize(html(text)) == HTMLDiff.normalize(try EngineSnapshots.value("front-matter/" + name)))
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
        for (index, text) in try Self.tocTexts().enumerated() {
            let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
            #expect(cmark.contains("<ul class=\"toc\">"))
            #expect(HTMLDiff.normalize(cmark) == HTMLDiff.normalize(try EngineSnapshots.value("toc/\(index)")))
        }
        #expect(!html("[TOC]\n\n# A\n").contains("class=\"toc\""))    // off by default
    }

    /// Hard wrap (FR-13): with the setting on, a soft break is <br>.
    @Test func hardWrap() throws {
        var settings = CorpusTests.settings
        settings.hardWrap = true
        let text = "one\ntwo\nthree\n"
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark == (try EngineSnapshots.value("hard-wrap")))
        #expect(!html(text).contains("<br>"))
        // Also in tight list items, which hoedown skipped (its rule was in
        // the paragraph renderer).
        #expect(MarkdownDocumentModel("- a\n  b\n", options: .init(settings)).body
                == "<ul>\n<li>a<br>\nb</li>\n</ul>\n")
    }

    /// Math (FR-14): put back in MathJax's delimiters, content escaped, as
    /// hoedown did, untouched by Markdown.
    @Test(arguments: [false, true])
    func math(inlineDollar: Bool) throws {
        var settings = CorpusTests.settings
        settings.math = true
        settings.inlineDollar = inlineDollar
        for (index, text) in Self.mathTexts.enumerated() {
            let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
            #expect(cmark == (try EngineSnapshots.value("math/\(inlineDollar)/\(index)")), "\(text.debugDescription)")
        }
    }

    /// Autolink (FR-8a): bare URLs and emails only with the setting on;
    /// <url> always.
    @Test func autolinks() throws {
        let text = Self.autolinkText
        var settings = CorpusTests.settings
        let off = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(off.components(separatedBy: "<a href").count == 2)    // just <https://x.org>
        settings.autolink = true
        let on = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(on == (try EngineSnapshots.value("autolink")))
    }

    /// Smart punctuation (FR-17): curly quotes, dashes and ellipses with
    /// the setting on, never in code. cmark writes the characters where
    /// hoedown wrote entities, so compare with entities decoded.
    @Test func smartPunctuation() throws {
        let text = Self.smartText
        var settings = CorpusTests.settings
        #expect(MarkdownDocumentModel(text, options: .init(settings)).body.contains("&quot;Double,&quot;"))
        settings.smartPunctuation = true
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark.contains("“Double,” ‘single,’ it’s, en – dash, em — dash…"))
        #expect(HTMLDiff.normalize(cmark) == HTMLDiff.normalize(try EngineSnapshots.value("smart-punctuation")))
    }

    /// Highlight and superscript (FR-19, FR-19a): in plain text, with their
    /// settings on.
    @Test func highlightAndSuperscript() throws {
        let text = Self.markText
        var settings = CorpusTests.settings
        #expect(!MarkdownDocumentModel(text, options: .init(settings)).body.contains("<mark>"))
        settings.highlight = true
        settings.superscript = true
        let cmark = MarkdownDocumentModel(text, options: .init(settings)).body
        #expect(cmark == (try EngineSnapshots.value("highlight-superscript")))
    }

    /// Source lines (FR-18): every block in the preview names its first
    /// source line; exports don't.
    @Test func sourceLines() {
        let text = "# Title\n\nPara\ngraph.\n\n> quote\n\n- a\n- b\n\n```\ncode\n```\n\n| t |\n|---|\n| 1 |\n\n---\n"
        var options = MarkdownDocumentModel.Options()
        options.sourceLines = true
        let body = MarkdownDocumentModel(text, options: options).body
        for tag in [#"<h1 data-source-line="1" id="toc_0">"#, #"<p data-source-line="3">"#,
                    #"<blockquote data-source-line="6">"#, #"<ul data-source-line="8">"#,
                    #"<li data-source-line="9">"#, #"<div data-source-line="11">"#,
                    #"<table data-source-line="15">"#, #"<hr data-source-line="19">"#] {
            #expect(body.contains(tag), "\(tag)")
        }
        #expect(!html(text).contains("data-source-line"))
        #expect(PageBuilder.withoutSourceLines(body) == html(text))
        let export = PageBuilder.exportHTML(title: nil, result: ParseResult(body: body, languages: []),
                                            settings: PageSettings(), withStyles: false, withHighlighting: false)
        #expect(!export.contains("data-source-line"))
    }

    /// Code in a footnote still loads its Prism language, and a header in
    /// one gets the next toc_N id.
    @Test func footnoteContent() {
        let model = MarkdownDocumentModel("# A\n\nNote[^n].\n\n# B\n\n[^n]: Code:\n\n    ### In a note\n\n    ```swift\n    let x = 1\n    ```\n", options: .init())
        #expect(model.languages.contains("swift"))
        let ids = model.body.matches(of: /id="toc_(\d+)"/).map { String($0.1) }
        #expect(Set(ids).count == ids.count, "\(ids)")
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

/// The renderer collects the Prism languages hoedown did (FR-10).
@MainActor @Suite struct PrismLanguageTests {
    @Test(arguments: try Corpus.all())
    func sameLanguagesAsHoedown(_ document: Corpus.Document) throws {
        let hoedown = try EngineSnapshots.value("languages/" + document.name).split(separator: " ").map(String.init)
        let cmark = MarkdownDocumentModel(document.text, options: .init(CorpusTests.settings)).languages
        #expect(Set(cmark) == Set(hoedown), "\(document.name)")
    }
}

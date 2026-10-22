//
//  HTMLToMarkdownTests.swift
//  MacDownKitTests
//
//  Converting pasted HTML to Markdown.
//

import AppKit
import Testing
@testable import MacDownKit

/// Options the fixtures' expected Markdown is written for (new-install
/// editing defaults), so tests don't depend on `Options()`.
let pasteTestOptions = HTMLToMarkdown.Options(listMarker: "-", indent: "    ")

func markdown(_ html: String, _ options: HTMLToMarkdown.Options = pasteTestOptions) -> String? {
    HTMLToMarkdown(options: options).convert(html)?.markdown
}

@Suite struct HTMLToMarkdownTests {
    @Test func singleParagraphIsInline() throws {
        let result = try #require(HTMLToMarkdown(options: pasteTestOptions).convert("<p>Hello</p>"))
        #expect(result.markdown == "Hello")
        #expect(result.isInline)
    }

    @Test func blocksAreSeparatedByOneBlankLine() throws {
        let result = try #require(HTMLToMarkdown(options: pasteTestOptions).convert("<p>One</p><p>Two</p>"))
        #expect(result.markdown == "One\n\nTwo\n")
        #expect(!result.isInline)
    }

    @Test func inlineContentBetweenBlocksBecomesParagraphs() {
        #expect(markdown("<div>Lead <span>in</span><p>Middle</p>Tail</div>") == "Lead in\n\nMiddle\n\nTail\n")
    }

    @Test func textWithoutTags() {
        #expect(markdown("Just text") == "Just text")
    }

    /// XMLDocument skips repairing short input and well-formed XML.
    @Test func shortAndWellFormedInput() {
        #expect(markdown("<p>x</p>") == "x")
        #expect(markdown("<b>x</b> y") == "**x** y")
        #expect(markdown("x") == "x")
        #expect(markdown("<P>Upper</P><P>case</P>") == "Upper\n\ncase\n")
    }

    /// Tidy only knows HTML 4 and drops HTML5 elements, keeping their
    /// content; block ones are renamed so their boundaries survive.
    @Test func html5BlockElementsKeepTheirBoundaries() {
        #expect(markdown("<section>One</section><article>Two</article><figure><figcaption>Three</figcaption></figure>")
                    == "One\n\nTwo\n\nThree\n")
        #expect(markdown("<p>A <mark>marked</mark> word</p>") == "A marked word")
    }

    @Test func commentsAndHeadAreIgnored() {
        #expect(markdown("<html><head><title>T</title></head><body><!--StartFragment--><p>Body</p><!--EndFragment--></body></html>")
                    == "Body")
    }

    @Test func nothingToConvertIsNil() {
        #expect(HTMLToMarkdown(options: pasteTestOptions).convert("") == nil)
        #expect(HTMLToMarkdown(options: pasteTestOptions).convert("<p> </p>") == nil)
    }
}

/// Bold, italic, strikethrough and monospace come from tags, `<style>` class
/// rules, inline styles and ancestors, since apps like Google Docs, Word and
/// AppKit's RTF export mark formatting with styles instead of tags.
@Suite struct HTMLToMarkdownStyleTests {
    typealias Style = HTMLToMarkdown.TextStyle

    /// Each text run's text and style, in order.
    func runs(_ html: String) -> [(String, Style)] {
        HTMLToMarkdown.blocks(html).flatMap { block -> [(String, Style)] in
            guard case .paragraph(let inlines) = block else { return [] }
            return inlines.compactMap { inline -> (String, Style)? in
                if case .text(let text, let style) = inline { (text, style) } else { nil }
            }
        }
    }

    func style(of text: String, in html: String) -> Style? {
        runs(html).first { $0.0.contains(text) }?.1
    }

    @Test func tags() {
        let html = "<p><b>B</b> <strong>S</strong> <i>I</i> <em>E</em> <s>X</s> <del>D</del> <strike>K</strike> <code>C</code> <kbd>Y</kbd></p>"
        #expect(style(of: "B", in: html) == Style(bold: true))
        #expect(style(of: "S", in: html) == Style(bold: true))
        #expect(style(of: "I", in: html) == Style(italic: true))
        #expect(style(of: "E", in: html) == Style(italic: true))
        for text in ["X", "D", "K"] { #expect(style(of: text, in: html) == Style(strike: true)) }
        for text in ["C", "Y"] { #expect(style(of: text, in: html) == Style(monospace: true)) }
    }

    @Test func inlineStyles() {
        let html = """
            <p><span style="font-weight:700">B</span><span style="font-weight: bold">W</span>\
            <span style="font-style:italic">I</span><span style="text-decoration:line-through">X</span>\
            <span style="font-family:'Roboto Mono',monospace">C</span><span style="font-weight:400">N</span></p>
            """
        #expect(style(of: "B", in: html) == Style(bold: true))
        #expect(style(of: "W", in: html) == Style(bold: true))
        #expect(style(of: "I", in: html) == Style(italic: true))
        #expect(style(of: "X", in: html) == Style(strike: true))
        #expect(style(of: "C", in: html) == Style(monospace: true))
        #expect(style(of: "N", in: html) == Style())
    }

    /// Google Docs wraps everything in a `b` styled as normal weight.
    @Test func normalWeightCancelsBoldTag() {
        let html = #"<b style="font-weight:normal;" id="docs-internal-guid-1"><p><span style="font-weight:700">B</span><span style="font-weight:400">N</span> plain</p></b>"#
        #expect(style(of: "B", in: html) == Style(bold: true))
        #expect(style(of: "N", in: html) == Style())
        #expect(style(of: "plain", in: html) == Style())
    }

    /// AppKit's RTF export puts fonts in classes, with the `font` shorthand.
    @Test func classRulesAndFontShorthand() {
        let html = """
            <html><head><style type="text/css">
            p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Helvetica; color: #000000}
            span.s1 {font: 12.0px Menlo}
            .heavy {font: bold italic 14px/1.2 "Helvetica Neue", sans-serif}
            </style></head><body>
            <p class="p1">Plain <b>bold</b> <span class="s1">code</span> <span class="heavy">heavy</span></p>
            </body></html>
            """
        #expect(style(of: "Plain", in: html) == Style())
        #expect(style(of: "bold", in: html) == Style(bold: true))
        #expect(style(of: "code", in: html) == Style(monospace: true))
        #expect(style(of: "heavy", in: html) == Style(bold: true, italic: true))
    }

    /// Word's styles sit in a comment inside `<style>`, next to `@` rules,
    /// and its `mso-` properties aren't the standard ones.
    @Test func wordStyles() {
        let html = """
            <html><head><style>
            <!--
            /* Style Definitions */
            p.MsoNormal, li.MsoNormal {margin:0in;font-family:"Calibri",sans-serif;}
            @list l0:level1 {mso-level-text:\\F0B7;}
            span.Code {font-family:Consolas;}
            -->
            </style></head><body>
            <p class=MsoNormal>Text <span style='font-family:"Courier New";mso-fareast-font-family:"Times New Roman"'>courier</span> \
            <span style='mso-bidi-font-family:"Courier New"'>not</span> <span class=Code>consolas</span></p>
            </body></html>
            """
        #expect(style(of: "Text", in: html) == Style())
        #expect(style(of: "courier", in: html) == Style(monospace: true))
        #expect(style(of: "not", in: html) == Style())
        #expect(style(of: "consolas", in: html) == Style(monospace: true))
    }

    /// Styles inherit: VS Code sets its font on the outer `div`.
    @Test func inheritance() {
        let html = #"<div style="font-family: Menlo, Monaco, 'Courier New', monospace;font-weight: normal;"><div><span style="color: #569cd6;">let</span></div></div>"#
        #expect(style(of: "let", in: html) == Style(monospace: true))
        #expect(style(of: "in", in: #"<p style="font-family: Helvetica"><code>x</code> <b style="font-style:italic">in</b></p>"#)
                    == Style(bold: true, italic: true))
        // A proportional font inside code turns monospace off.
        #expect(style(of: "y", in: #"<code><span style="font-family: Georgia, serif">y</span></code>"#) == Style())
    }

    /// Inline styles beat class rules, and class rules beat tag defaults.
    @Test func precedence() {
        let html = """
            <style>.light {font-weight: normal} b.heavy {font-weight: 800} .it {font-style: italic}</style>
            <p><b class="light">L</b> <span class="heavy">S</span> <b class="heavy">H</b> <span class="it" style="font-style: normal">N</span></p>
            """
        #expect(style(of: "L", in: html) == Style())
        #expect(style(of: "S", in: html) == Style())
        #expect(style(of: "H", in: html) == Style(bold: true))
        #expect(style(of: "N", in: html) == Style())
    }
}

/// Whitespace as a browser shows it.
@Suite struct HTMLToMarkdownTextTests {
    @Test func whitespaceCollapses() {
        #expect(markdown("<p>  Hello\n   wide\tworld  </p>") == "Hello wide world")
        #expect(markdown("<p>a <b> b</b>  c</p>")?.replacingOccurrences(of: "*", with: "") == "a b c")
        #expect(markdown("<p>one<span> </span><span> </span>two</p>") == "one two")
    }

    @Test func entitiesAreDecoded() {
        #expect(markdown("<p>caf&eacute; &#8617; &#x2014;</p>") == "café ↩ —")
    }

    @Test func nonBreakingSpacesBecomeSpacesOutsideCode() {
        #expect(markdown("<p>a&nbsp;b&nbsp;&nbsp;</p>") == "a b")
        let runs = HTMLToMarkdown.blocks("<p><code>a&nbsp;b</code></p>").flatMap { block -> [String] in
            guard case .paragraph(let inlines) = block else { return [] }
            return inlines.map { if case .text(let text, _) = $0 { text } else { "" } }
        }
        #expect(runs == ["a\u{a0}b"])
    }
}

/// Characters are escaped only where they'd change the Markdown.
@Suite struct HTMLToMarkdownEscapingTests {
    func escaped(_ text: String) -> String {
        HTMLToMarkdown.Renderer.escape(text, atLineStart: true)
    }

    @Test func markupCharacters() {
        #expect(escaped("2 * 3, [link], `tick`, ~tilde~") == #"2 \* 3, \[link\], \`tick\`, \~tilde\~"#)
    }

    @Test func underscoresOnlyAtWordBoundaries() {
        #expect(escaped("snake_case and _word_ and __init__") == #"snake_case and \_word\_ and \_\_init\_\_"#)
    }

    @Test func backslashesOnlyBeforePunctuation() {
        #expect(escaped(##"C:\Users\me and a\*b and end\"##) == ##"C:\Users\me and a\\\*b and end\"##)
    }

    @Test func angleBracketsAndAmpersands() {
        #expect(escaped("<div> and 1 < 2 and a > b, </p>, <!-- x") == #"\<div> and 1 < 2 and a > b, \</p>, \<!-- x"#)
        #expect(escaped("AT&T &amp; &#123; & more") == #"AT&T \&amp; \&#123; & more"#)
    }

    @Test func blockMarkersAtLineStart() {
        #expect(escaped("# not a heading") == "\\# not a heading")
        #expect(escaped("### three") == "\\### three")
        #expect(escaped("#hashtag") == "#hashtag")
        #expect(escaped("> not a quote") == #"\> not a quote"#)
        #expect(escaped("- not an item") == #"\- not an item"#)
        #expect(escaped("+ plus") == #"\+ plus"#)
        #expect(escaped("1. First") == #"1\. First"#)
        #expect(escaped("12) Twelfth") == #"12\) Twelfth"#)
        #expect(escaped("===") == #"\==="#)
        #expect(escaped("---") == #"\---"#)
        #expect(escaped("-5 degrees") == "-5 degrees")
        #expect(escaped("1.5 litres") == "1.5 litres")
    }

    @Test func blockMarkersElsewhereAreLeftAlone() {
        let text = "Chapter 1. Begins - then + more > less # tag ==="
        #expect(HTMLToMarkdown.Renderer.escape(text, atLineStart: false) == text)
        #expect(escaped(text) == text)
    }

    @Test func paragraphsAreEscaped() {
        #expect(markdown("<p>1. Not a list *really*</p>") == #"1\. Not a list \*really\*"#)
    }
}

/// Blocks are separated by one blank line, with no blank lines at the
/// start, and a trailing newline only after blocks.
@Suite struct HTMLToMarkdownOutputTests {
    let renderer = HTMLToMarkdown.Renderer(options: pasteTestOptions)
    typealias Block = HTMLToMarkdown.Block

    func paragraph(_ text: String) -> Block { .paragraph([.text(text, .init())]) }

    @Test func emptyBlocksAddNoBlankLines() {
        #expect(markdown("<p></p><br><p>a</p><div> <br> </div><p></p><p>b</p><p>&nbsp;</p>") == "a\n\nb\n")
    }

    @Test func blocksWithBlankEdgesAreTrimmed() {
        let result = renderer.render([paragraph("one"), .paragraph([]), paragraph("two")])
        #expect(result == .init(markdown: "one\n\ntwo\n", isInline: false))
    }

    @Test func oneParagraphIsInlineWithoutNewline() {
        #expect(renderer.render([paragraph("only")]) == .init(markdown: "only", isInline: true))
        #expect(markdown("<div><div><p>nested <b>only</b></p></div></div>")?.hasSuffix("\n") == false)
    }
}

/// Headings, paragraphs and line breaks.
@Suite struct HTMLToMarkdownHeadingTests {
    @Test func atxHeadings() {
        #expect(markdown("<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><h6>Six</h6>")
                    == "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n")
    }

    @Test func headingContentIsOneLineWithoutBold() {
        #expect(markdown("<h2><b>Bold</b> <span style=\"font-weight:700\">title</span><br>split</h2>")
                    == "## Bold title split\n")
        // Tidy moves blocks out of headings.
        #expect(markdown("<h1><div>Block</div><p>inside</p></h1>") == "# Block\n\ninside\n")
    }

    @Test func emptyHeadingsAreDropped() {
        #expect(markdown("<h1> </h1><p>Text</p>") == "Text")
    }

    @Test func headingTextIsEscaped() {
        #expect(markdown("<h2>1. Intro *now*</h2>") == "## 1. Intro \\*now\\*\n")
        // A trailing run of # would be read as a closing sequence.
        #expect(markdown("<h2>Learn C#</h2><h3>Issue #</h3>") == "## Learn C#\n\n### Issue \\#\n")
    }

    @Test func lineBreaksInParagraphs() {
        #expect(markdown("<p>one<br>two <br/> three</p>") == "one\\\ntwo\\\nthree")
        #expect(markdown("<p>line<br>- not a list</p>") == "line\\\n\\- not a list")
    }

    @Test func breaksAtEdgesAreDropped() {
        #expect(markdown("<p><br>text<br></p>") == "text")
        #expect(markdown("<p>a</p><br><br><p>b</p>") == "a\n\nb\n")
    }

    @Test func doubleBreaksSplitParagraphs() {
        #expect(markdown("<p>first<br><br>second<br><br><br>third</p>") == "first\n\nsecond\n\nthird\n")
    }

    @Test func divsAndParagraphs() {
        #expect(markdown("<div>One</div><div><div>Two</div></div><p>Three</p>") == "One\n\nTwo\n\nThree\n")
    }
}

/// Bold, italic and strikethrough.
@Suite struct HTMLToMarkdownEmphasisTests {
    @Test func markers() {
        #expect(markdown("<p><b>bold</b> and <i>italic</i> and <s>struck</s></p>") == "**bold** and *italic* and ~~struck~~")
        #expect(markdown("<p>in<b>side</b>word</p>") == "in**side**word")
    }

    @Test func nesting() {
        #expect(markdown("<p><b>bold <i>both</i></b></p>") == "**bold *both***")
        #expect(markdown("<p><b><i>both</i></b> <s><b>all</b></s></p>") == "***both* ~~all~~**")
        // The emphasis spanning the most stays outermost, not split.
        #expect(markdown("<p><i>emphasis with <b>strong</b> inside</i> and <b>strong with <i>em</i> inside</b></p>")
                    == "*emphasis with **strong** inside* and **strong with *em* inside**")
    }

    /// Google Docs writes each run as its own styled span.
    @Test func adjacentRunsMerge() {
        #expect(markdown(#"<p><span style="font-weight:700">one</span><span style="font-weight:700"> two</span> <span style="font-weight:700">three</span></p>"#)
                    == "**one two three**")
        #expect(markdown("<p><i>a</i><i>b</i></p>") == "*ab*")
    }

    @Test func whitespaceMovesOutsideMarkers() {
        #expect(markdown("<p>a<b> spaced </b>b</p>") == "a **spaced** b")
        #expect(markdown("<p><b> </b>text<i> </i></p>") == "text")
    }

    @Test func normalWeightInsideBold() {
        #expect(markdown(#"<p><b>bold <span style="font-weight:normal">plain</span> bold</b></p>"#) == "**bold** plain **bold**")
    }

    @Test func lineBreaksCloseMarkers() {
        #expect(markdown("<p><b>one<br>two</b></p>") == "**one**\\\n**two**")
    }

    @Test func textInsideMarkersIsEscaped() {
        #expect(markdown("<p><b>*star*</b></p>") == "**\\*star\\***")
        #expect(markdown("<p><b>1. Bold</b></p>") == "**1. Bold**")
        // A backslash right before a closing marker stays a backslash.
        #expect(markdown(#"<p><i>path\</i></p>"#) == #"*path\\*"#)
    }

    @Test func headingsKeepItalic() {
        #expect(markdown("<h2>A <i>b</i> <b>c</b></h2>") == "## A *b* c\n")
    }
}

/// Code and monospace text.
@Suite struct HTMLToMarkdownInlineCodeTests {
    @Test func codeSpans() {
        #expect(markdown("<p>Run <code>make install</code> now, press <kbd>⌘K</kbd></p>") == "Run `make install` now, press `⌘K`")
        #expect(markdown(#"<p>Use <span style="font-family:'Roboto Mono',monospace">inline code</span>.</p>"#) == "Use `inline code`.")
    }

    @Test func contentIsNotEscaped() {
        #expect(markdown("<p><code>*not* _emph_ [x] &lt;b&gt; \\n</code></p>") == "`*not* _emph_ [x] <b> \\n`")
    }

    @Test func backticksInContent() {
        #expect(markdown("<p><code>a`b</code></p>") == "``a`b``")
        #expect(markdown("<p><code>``x</code></p>") == "``` ``x ```")
        #expect(markdown("<p><code>`tick`</code></p>") == "`` `tick` ``")
    }

    /// Tidy moves spaces at the edges of inline elements outside them.
    @Test func edgeSpaces() {
        #expect(markdown("<p>x<code>1. </code>z</p>") == "x`1.` z")
        #expect(markdown("<p>x<code> y </code>z</p>") == "x `y` z")
        #expect(markdown("<p>a <code> </code> b</p>") == "a b")
    }

    /// Spaces that reach a code span are kept, padded so CommonMark keeps
    /// them too.
    @Test func codeSpanPadding() {
        typealias Renderer = HTMLToMarkdown.Renderer
        #expect(Renderer.codeSpan("1. ") == "`1. `")
        #expect(Renderer.codeSpan(" y ") == "`  y  `")
        #expect(Renderer.codeSpan("a b") == "`a b`")
    }

    @Test func adjacentCodeMerges() {
        #expect(markdown("<p><code>a</code><code>b</code> <code>c</code></p>") == "`ab c`")
    }

    @Test func codeInsideEmphasis() {
        #expect(markdown("<p><b>see <code>x</code></b></p>") == "**see `x`**")
        #expect(markdown("<p><code><b>bold code</b></code></p>") == "**`bold code`**")
    }
}

/// Preformatted text as fenced code blocks.
@Suite struct HTMLToMarkdownCodeBlockTests {
    @Test func fencedWithLanguage() {
        #expect(markdown(#"<pre><code class="language-swift">let a = 1&#10;print(a)&#10;</code></pre>"#)
                    == "```swift\nlet a = 1\nprint(a)\n```\n")
        #expect(markdown(#"<pre class="lang-python">x = 1</pre>"#) == "```python\nx = 1\n```\n")
        #expect(markdown("<pre>plain</pre>") == "```\nplain\n```\n")
    }

    @Test func textIsVerbatim() {
        #expect(markdown("<pre>  indented\n    *more* _b_ &lt;c&gt;\n\n  after blank</pre>")
                    == "```\n  indented\n    *more* _b_ <c>\n\n  after blank\n```\n")
    }

    /// MacDown's preview: Prism's token spans inside a wrapper div.
    @Test func highlightingSpansAreText() {
        #expect(markdown(#"<div><pre class="language-js"><code class="language-js"><span class="token keyword" style="color: blue">let</span> x <span class="token operator">=</span> 1</code></pre></div>"#)
                    == "```js\nlet x = 1\n```\n")
    }

    @Test func lineBreakElements() {
        #expect(markdown("<pre>a<br>b<br/>c</pre>") == "```\na\nb\nc\n```\n")
    }

    @Test func fenceIsLongerThanBackticksInside() {
        #expect(markdown("<pre>```\ncode\n```</pre>") == "````\n```\ncode\n```\n````\n")
    }

    @Test func betweenParagraphs() {
        #expect(markdown("<p>Before</p><pre>x</pre><p>After</p>") == "Before\n\n```\nx\n```\n\nAfter\n")
        #expect(markdown("<pre>\n\n</pre><p>Only</p>") == "Only")
    }
}

/// Links.
@Suite struct HTMLToMarkdownLinkTests {
    @Test func inlineLinks() {
        #expect(markdown(#"<p>Read <a href="https://example.com/x" title="X">the guide</a>.</p>"#)
                    == #"Read [the guide](https://example.com/x "X")."#)
        #expect(markdown(#"<p><a href="https://e.com" title='say "hi"'>t</a></p>"#) == #"[t](https://e.com "say \"hi\"")"#)
    }

    @Test func autolinks() {
        #expect(markdown(#"<p><a href="https://example.com/">https://example.com/</a></p>"#) == "<https://example.com/>")
        #expect(markdown(#"<p><a href="mailto:a@b.com">a@b.com</a></p>"#) == "<a@b.com>")
    }

    @Test func linksThatOnlyKeepText() {
        #expect(markdown(#"<p>or <a href="javascript:void(0)">click here</a>.</p>"#) == "or click here.")
        #expect(markdown(##"<p>jump to <a href="#install">installing</a></p>"##) == "jump to installing")
        #expect(markdown(#"<p><a>no href</a></p>"#) == "no href")
    }

    @Test func emptyLinksAreDropped() {
        #expect(markdown(##"<h2><a class="anchor" href="#setup"><i class="fa fa-link"></i></a>Setup</h2>"##) == "## Setup\n")
        #expect(markdown(#"<p><a href="https://x.com"> </a>text</p>"#) == "text")
    }

    @Test func destinations() {
        #expect(markdown(#"<p><a href="https://x.com/a b">t</a></p>"#) == "[t](https://x.com/a%20b)")
        #expect(markdown(#"<p><a href="https://en.wikipedia.org/wiki/Swift_(language)">w</a></p>"#)
                    == "[w](https://en.wikipedia.org/wiki/Swift_(language))")
        #expect(markdown(#"<p><a href="https://x.com/a)">t</a></p>"#) == "[t](<https://x.com/a)>)")
    }

    @Test func relativeLinksResolveAgainstTheBaseURL() {
        var options = pasteTestOptions
        options.baseURL = URL(string: "https://example.com/guide/start.html")
        #expect(markdown(#"<p><a href="../ref/api.html">API</a> <a href="/">Home</a></p>"#, options)
                    == "[API](https://example.com/ref/api.html) [Home](https://example.com/)")
        #expect(markdown(#"<p><a href="../ref/api.html">API</a></p>"#) == "[API](../ref/api.html)")
    }

    @Test func linkContent() {
        #expect(markdown(#"<p><a href="u"><b>bold</b> link</a></p>"#) == "[**bold** link](u)")
        #expect(markdown(#"<p><a href="u">[1]</a></p>"#) == #"[\[1\]](u)"#)
        #expect(markdown(#"<p><a href="u"> spaced </a>x</p>"#) == "[spaced](u) x")
        #expect(markdown(#"<p><b>see <a href="u">this</a></b></p>"#) == "**see** [**this**](u)")
    }
}

/// Images keep their address and are never fetched.
@Suite struct HTMLToMarkdownImageTests {
    @Test func images() {
        #expect(markdown(#"<p><img src="https://e.com/a.png" alt="A pic" title="T"></p>"#) == #"![A pic](https://e.com/a.png "T")"#)
        #expect(markdown(#"<p>See <img src="a.png"> here</p>"#) == "See ![](a.png) here")
        #expect(markdown(#"<p><img src="data:image/png;base64,iVBORw0K"></p>"#) == "![](data:image/png;base64,iVBORw0K)")
        #expect(markdown(#"<p><img src="a b.png" alt="[x] *y*"></p>"#) == #"![\[x\] \*y\*](a%20b.png)"#)
    }

    @Test func relativeSourcesResolveAgainstTheBaseURL() {
        var options = pasteTestOptions
        options.baseURL = URL(string: "https://example.com/guide/")
        #expect(markdown(#"<p><img src="images/d.png" alt="D"></p>"#, options) == "![D](https://example.com/guide/images/d.png)")
    }

    @Test func linkedImages() {
        #expect(markdown(#"<p><a href="https://e.com"><img src="i.png" alt="logo"></a></p>"#) == "[![logo](i.png)](https://e.com)")
    }

    @Test func imagesWithoutSourcesAreDropped() {
        #expect(markdown(#"<p>x<img alt="y"></p>"#) == "x")
    }

    @Test func imagesBetweenBlocks() {
        #expect(markdown(#"<p>a</p><img src="i.png"><p>b</p>"#) == "a\n\n![](i.png)\n\nb\n")
        #expect(markdown(#"<h2><img src="i.png" alt="icon"> Title</h2>"#) == "## ![icon](i.png) Title\n")
    }
}

/// Bulleted and numbered lists.
@Suite struct HTMLToMarkdownListTests {
    func options(_ marker: String, _ indent: String = "    ") -> HTMLToMarkdown.Options {
        .init(listMarker: marker, indent: indent)
    }

    @Test(arguments: ["-", "*", "+"])
    func bulletsUseTheMarkerSetting(_ marker: String) {
        #expect(markdown("<ul><li>a</li><li>b</li></ul>", options(marker)) == "\(marker) a\n\(marker) b\n")
    }

    @Test func numberedListsKeepTheirStart() {
        #expect(markdown(#"<ol start="3"><li>x</li><li>y</li></ol>"#) == "3. x\n4. y\n")
        #expect(markdown("<ol><li>x</li></ol>") == "1. x\n")
    }

    @Test func nestingUsesTheIndentSetting() {
        let html = "<ul><li>a<ul><li>b<ol><li>c</li></ol></li></ul></li><li>d</li></ul>"
        #expect(markdown(html) == "- a\n    - b\n        1. c\n- d\n")
        #expect(markdown(html, options("*", "\t")) == "* a\n\t* b\n\t\t1. c\n* d\n")
    }

    /// Continuation lines and sublists start at least at the content column.
    @Test func wideMarkersIndentFurther() {
        #expect(markdown(#"<ol start="99"><li>x</li><li>y<ul><li>z</li></ul></li></ol>"#) == "99. x\n100. y\n     - z\n")
        #expect(markdown("<ul><li>a<br>b</li></ul>") == "- a\\\n    b\n")
    }

    /// A numbered list not starting at 1 can't interrupt a paragraph.
    @Test func numberedSublistsNotStartingAtOne() {
        #expect(markdown(#"<ul><li>a<ol start="2"><li>b</li></ol></li></ul>"#) == "- a\n\n    2. b\n")
    }

    @Test func looseAndTightLists() {
        // Paragraphs in items mean a loose list, unless they have no
        // margins (Google Docs).
        #expect(markdown("<ul><li><p>a</p></li><li><p>b</p></li></ul>") == "- a\n\n- b\n")
        #expect(markdown(#"<ul><li><p style="margin-top:0pt;margin-bottom:0pt;">a</p></li><li><p style="margin: 0.0px 0.0px 0.0px 0.0px">b</p></li></ul>"#)
                    == "- a\n- b\n")
        #expect(markdown("<ul><li><p>a</p><p>a2</p></li><li><p>b</p></li></ul>") == "- a\n\n    a2\n\n- b\n")
        #expect(markdown("<ul><li>a<pre>x</pre></li></ul>") == "- a\n\n    ```\n    x\n    ```\n")
    }

    /// Google Docs puts a sublist directly in its parent list, which Tidy
    /// wraps in an item of its own.
    @Test func sublistsOutsideItemsJoinThePreviousItem() {
        #expect(markdown("<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>") == "- a\n    - b\n- c\n")
    }

    /// Two lists in a row would merge into one with the same marker.
    @Test func adjacentListsUseAnotherMarker() {
        #expect(markdown("<ul><li>a</li></ul><ul><li>b</li></ul>") == "- a\n\n* b\n")
        #expect(markdown("<ul><li>a</li></ul><ul><li>b</li></ul>", options("*")) == "* a\n\n- b\n")
        #expect(markdown("<ol><li>a</li></ol><ol><li>b</li></ol>") == "1. a\n\n1) b\n")
    }

    @Test func itemTextIsEscaped() {
        #expect(markdown("<ol><li>1. not nested</li><li>- nor this</li></ol>") == "1. 1\\. not nested\n2. \\- nor this\n")
    }

    @Test func emptyItemsAreDropped() {
        #expect(markdown("<ul><li></li><li>b</li><li> </li></ul>") == "- b\n")
        #expect(markdown("<ul><li> </li></ul><p>x</p>") == "x")
    }

    @Test func listsBetweenParagraphs() {
        #expect(markdown("<p>Intro</p><ul><li>a</li></ul><p>After</p>") == "Intro\n\n- a\n\nAfter\n")
    }
}

/// Task lists.
@Suite struct HTMLToMarkdownTaskListTests {
    @Test func checkboxes() {
        #expect(markdown(#"<ul><li><input type="checkbox" checked> Done</li><li><input type="checkbox"> Open</li></ul>"#)
                    == "- [x] Done\n- [ ] Open\n")
        #expect(markdown(#"<ol><li><input type="checkbox"> a</li></ol>"#) == "1. [ ] a\n")
        #expect(markdown(#"<ul><li><input type="checkbox" checked>x</li></ul>"#, .init(listMarker: "*", indent: "\t")) == "* [x] x\n")
    }

    /// GitHub and MacDown's preview, and loose items with the box in a paragraph.
    @Test func renderedTaskLists() {
        #expect(markdown(#"<ul><li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled="" checked=""> Done</li></ul>"#)
                    == "- [x] Done\n")
        #expect(markdown(#"<ul><li><p><input type="checkbox" checked disabled>Done</p></li></ul>"#) == "- [x] Done\n")
    }

    @Test func otherInputsAreNotTasks() {
        #expect(markdown(#"<ul><li>text <input type="checkbox"></li><li><input type="radio"> radio</li></ul>"#)
                    == "- text\n- radio\n")
    }
}

/// Block quotes and rules.
@Suite struct HTMLToMarkdownQuoteTests {
    @Test func quotes() {
        #expect(markdown("<blockquote><p>Quoted</p></blockquote>") == "> Quoted\n")
        #expect(markdown("<blockquote>Plain text</blockquote>") == "> Plain text\n")
        #expect(markdown("<blockquote><p>a</p><p>b</p></blockquote>") == "> a\n>\n> b\n")
    }

    @Test func nestedQuotesAndBlocksInQuotes() {
        #expect(markdown("<blockquote><p>a</p><blockquote><p>b</p></blockquote></blockquote>") == "> a\n>\n> > b\n")
        #expect(markdown("<blockquote><ul><li>x</li><li>y</li></ul><pre>code</pre></blockquote>")
                    == "> - x\n> - y\n>\n> ```\n> code\n> ```\n")
    }

    @Test func quoteTextIsEscaped() {
        #expect(markdown("<blockquote><p>&gt; not nested</p></blockquote>") == "> \\> not nested\n")
    }

    @Test func emptyQuotesAreDropped() {
        #expect(markdown("<blockquote> </blockquote><p>x</p>") == "x")
    }

    @Test func rules() {
        #expect(markdown("<p>a</p><hr><p>b</p>") == "a\n\n***\n\nb\n")
        #expect(markdown("<p>a</p><hr><p>b</p>", .init(listMarker: "*", indent: "    ")) == "a\n\n---\n\nb\n")
        #expect(markdown("<hr>") == "***\n")
    }
}

/// Tables.
@Suite struct HTMLToMarkdownTableTests {
    @Test func pipeTables() {
        #expect(markdown(#"<table><thead><tr><th>Name</th><th align="right">Count</th></tr></thead><tbody><tr><td>Apples</td><td>3</td></tr></tbody></table>"#)
                    == "| Name | Count |\n| --- | ---: |\n| Apples | 3 |\n")
        // Without a header row, the first row is the header.
        #expect(markdown("<table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table>")
                    == "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
    }

    @Test func alignment() {
        #expect(markdown(#"<table><tr><th style="text-align: center">c</th><th style="text-align:left">l</th><th>n</th></tr></table>"#)
                    == "| c | l | n |\n| :---: | :--- | --- |\n")
    }

    @Test func pipesAreEscaped() {
        #expect(markdown("<table><tr><th>a|b</th></tr><tr><td><code>x|y</code></td></tr></table>")
                    == "| a\\|b |\n| --- |\n| `x\\|y` |\n")
    }

    /// Google Docs puts each cell's text in a paragraph.
    @Test func formattingInCells() {
        #expect(markdown("<table><tr><td><p><b>Name</b></p></td></tr><tr><td><p>x <i>y</i><br>z</p></td></tr></table>")
                    == "| **Name** |\n| --- |\n| x *y* z |\n")
    }

    @Test func shortRowsArePadded() {
        #expect(markdown("<table><tr><th>a</th><th>b</th></tr><tr><td>1</td></tr></table>")
                    == "| a | b |\n| --- | --- |\n| 1 |  |\n")
    }

    @Test func mergedCellsStayHTML() {
        let html = #"<table><tr><th>Region</th><th colspan="2">Quarter</th></tr><tr><td rowspan="2">North</td><td>Q1</td><td>Q2</td></tr><tr><td>10 &lt; 20 &amp; more</td><td><b>20</b></td></tr></table>"#
        #expect(markdown(html) == """
            <table>
            <tbody>
            <tr><th>Region</th><th colspan="2">Quarter</th></tr>
            <tr><td rowspan="2">North</td><td>Q1</td><td>Q2</td></tr>
            <tr><td>10 &lt; 20 &amp; more</td><td><strong>20</strong></td></tr>
            </tbody>
            </table>

            """)
        #expect(markdown("<table><thead><tr><th colspan=2>h</th></tr></thead><tbody><tr><td>a</td><td>b</td></tr></tbody></table>") == """
            <table>
            <thead>
            <tr><th colspan="2">h</th></tr>
            </thead>
            <tbody>
            <tr><td>a</td><td>b</td></tr>
            </tbody>
            </table>

            """)
    }

    @Test func blockContentStaysHTML() {
        #expect(markdown(#"<table><tr><td><ul><li>a</li><li><a href="u">b</a></li></ul></td><td><p>one</p><p>two</p></td></tr></table>"#) == """
            <table>
            <tbody>
            <tr><td><ul><li>a</li><li><a href="u">b</a></li></ul></td><td><p>one</p><p>two</p></td></tr>
            </tbody>
            </table>

            """)
    }

    @Test func captionsAndSurroundings() {
        #expect(markdown("<p>Before</p><table><caption>Cap</caption><tr><td>a</td></tr></table><p>After</p>")
                    == "Before\n\nCap\n\n| a |\n| --- |\n\nAfter\n")
        #expect(markdown("<table><tr><td> </td></tr></table><p>x</p>") == "x")
    }
}

/// Formatting without a Markdown equivalent keeps its text; what isn't
/// content is dropped.
@Suite struct HTMLToMarkdownDroppedTests {
    @Test func formattingWithoutEquivalentKeepsText() {
        #expect(markdown("<p>H<sub>2</sub>O and x<sup>2</sup>, <u>under</u>, <mark>hi</mark>, <font color=red>red</font>, <span style=\"color: blue; font-size: 20px\">big</span></p>")
                    == "H2O and x2, under, hi, red, big")
    }

    @Test func nonContentIsDropped() {
        #expect(markdown("<p>a<script>alert(1)</script>b</p><style>p { color: red }</style><noscript>no</noscript><template><p>t</p></template>")
                    == "ab")
        #expect(markdown(#"<p>a<svg viewBox="0 0 1 1"><text>t</text></svg><iframe src="x"></iframe><select><option>o</option></select></p>"#) == "a")
    }

    /// Docs sites put a Copy button next to code.
    @Test func buttonsAreDropped() {
        #expect(markdown("<div><button>Copy</button><pre>code</pre></div>") == "```\ncode\n```\n")
    }

    @Test func hiddenContentIsDropped() {
        #expect(markdown(#"<p>shown<span style="display:none">hidden</span></p><div style="display: none"><p>gone</p></div>"#) == "shown")
    }

    /// Every word the reader sees survives, whatever the markup.
    @Test func visibleTextIsPreserved() {
        let html = """
            <h1>Title words</h1><p>Some <b>bold</b>, <i>italic</i> and <code>code</code> with a \
            <a href="https://e.com">link here</a>.</p><ul><li>first item<ul><li>nested item</li></ul></li></ul>\
            <blockquote><p>quoted text</p></blockquote><pre>let code = block</pre>\
            <table><tr><th>head cell</th></tr><tr><td>body cell</td></tr></table><p>H<sub>2</sub>O end</p>
            """
        func words(_ text: String) -> [String] {
            text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let expected = words("Title words Some bold italic and code with a link here first item nested item quoted text let code block head cell body cell H2O end")
        let converted = words((markdown(html) ?? "").replacingOccurrences(of: "(https://e.com)", with: ""))
        #expect(converted == expected)
    }
}

/// A long article converts well within a paste's time budget (paste
/// intent, Goals 4: under 50 ms). Measured 2026-10-21 on an M-series Mac:
/// help.md's 30 KB of HTML in 11 ms (release) / 21 ms (debug).
@Suite struct HTMLToMarkdownPerformanceTests {
    @Test func longArticleConvertsUnder50Milliseconds() throws {
        let help = try #require(try Corpus.all().first { $0.name == "help.md" })
        let html = MarkdownDocumentModel(help.text, options: .init()).body
        let converter = HTMLToMarkdown(options: pasteTestOptions)
        // The best of a few runs, so other suites running alongside don't
        // count.
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = converter.convert(html)
            best = min(best, ContinuousClock.now - start)
        }
        #expect(best < .milliseconds(50), "converted in \(best)")
    }
}

/// Code copied from a code editor or terminal is pasted as it is: all its
/// text is monospace, without structure.
@MainActor @Suite struct HTMLToMarkdownCodeDetectionTests {
    func isCode(_ html: String) -> Bool {
        HTMLToMarkdown(options: pasteTestOptions).convert(html)?.isCode ?? false
    }

    @Test func vsCode() throws {
        #expect(isCode(try #require(try PasteFixture.load("synthetic-vscode").html)))
    }

    /// Xcode and Terminal write only RTF; AppKit's HTML puts the font in
    /// classes.
    @Test func xcode() throws {
        let fixture = try PasteFixture.load("synthetic-xcode")
        let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try #require(fixture.rtf), forType: .rtf)
        guard case .html(let html, _)? = PasteboardContent.read(from: pasteboard) else {
            Issue.record("no HTML")
            return
        }
        #expect(isCode(html))
    }

    /// JetBrains IDEs copy a styled pre, with bold keywords.
    @Test func boldKeywordsAreStillCode() {
        #expect(isCode(#"<pre style="font-family:'JetBrains Mono',monospace"><span style="color:#cc7832;font-weight:bold;">fun </span>main() {}</pre>"#))
        #expect(isCode(#"<div style="font-family: Menlo"><b>let</b> x = 1<br>print(x)</div>"#))
    }

    @Test func formattedTextIsNotCode() throws {
        #expect(!isCode(try #require(try PasteFixture.load("synthetic-google-docs").html)))
        #expect(!isCode("<p>Run <code>make</code> now</p>"))
        #expect(!isCode(#"<div style="font-family: Menlo"><a href="https://e.com">link</a></div>"#))
        #expect(!isCode(#"<ul style="font-family: Menlo"><li>item</li></ul>"#))
        #expect(!isCode(#"<h1 style="font-family: Menlo">Title</h1>"#))
    }
}

/// Word's list paragraphs.
@Suite struct HTMLToMarkdownWordTests {
    static func item(_ level: Int, _ list: Int = 0, bullet: String, _ text: String) -> String {
        "<p class=MsoListParagraph style='margin-left:\(level * 36)pt;text-indent:-18pt;mso-list:l\(list) level\(level) lfo1'>"
            + "<![if !supportLists]><span style='font-family:Symbol'><span style='mso-list:Ignore'>\(bullet)"
            + "<span style='font:7.0pt \"Times New Roman\"'>&nbsp;&nbsp;&nbsp; </span></span></span><![endif]>"
            + "\(text)<o:p></o:p></p>"
    }

    @Test func bulletedAndNested() {
        let html = Self.item(1, bullet: "&middot;", "One") + Self.item(2, bullet: "o", "Two <b>bold</b>")
            + Self.item(3, bullet: "&sect;", "Three") + Self.item(1, bullet: "&middot;", "Four")
        #expect(markdown(html) == "- One\n    - Two **bold**\n        - Three\n- Four\n")
    }

    @Test func numbered() {
        let html = Self.item(1, 1, bullet: "3.", "Third") + Self.item(1, 1, bullet: "4.", "Fourth")
            + Self.item(2, 1, bullet: "a.", "Sub") + Self.item(2, 1, bullet: "b.", "Sub two")
        #expect(markdown(html) == "3. Third\n4. Fourth\n    1. Sub\n    2. Sub two\n")
    }

    /// A paragraph between, or another list, ends the list.
    @Test func separateLists() {
        let html = Self.item(1, 0, bullet: "&middot;", "A") + "<p class=MsoNormal>Between<o:p></o:p></p>"
            + Self.item(1, 0, bullet: "&middot;", "B") + Self.item(1, 2, bullet: "1.", "C")
        #expect(markdown(html) == "- A\n\nBetween\n\n- B\n\n1. C\n")
    }

    /// Word's empty paragraphs and namespaced elements leave nothing.
    @Test func emptyParagraphs() {
        #expect(markdown("<p class=MsoNormal>One<o:p></o:p></p><p class=MsoNormal><o:p>&nbsp;</o:p></p><p class=MsoNormal>Two</p>")
                    == "One\n\nTwo\n")
    }
}

/// Web pages.
@Suite struct HTMLToMarkdownWebTests {
    /// Lazily loaded images name their source in srcset or data-src.
    @Test func imagesWithoutSrc() {
        #expect(markdown(#"<p><img srcset="a.png 1x, a@2x.png 2x" alt="A"></p>"#) == "![A](a.png)")
        #expect(markdown(#"<p><img data-src="b.png" alt="B"></p>"#) == "![B](b.png)")
        #expect(markdown(#"<p><img alt="none"></p><p>x</p>"#) == "x")
    }

    /// Icon fonts: Private Use Area glyphs and Material icon names aren't
    /// text.
    @Test func iconFonts() {
        #expect(markdown("<p><span class=\"icon\">\u{F015}</span> Home</p>") == "Home")
        #expect(markdown(#"<p><span class="material-icons">search</span>Search</p>"#) == "Search")
        #expect(markdown(#"<p><span class="material-symbols-outlined">home</span> Home</p>"#) == "Home")
    }

    /// The fixture's links resolve against the page, in-page links keep
    /// their text and icon-only anchors disappear (see the fixture test).
    @Test func relativeLinksUseTheBaseElement() {
        var options = pasteTestOptions
        options.baseURL = URL(string: "https://e.com/docs/guide/")
        #expect(markdown(##"<p><a href="../api/">API</a> and <a href="#top">top</a></p>"##, options)
                    == "[API](https://e.com/docs/api/) and top")
    }
}

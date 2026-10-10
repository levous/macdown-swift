//
//  HighlightMapperTests.swift
//  MacDownKitTests
//
//  Span extents follow PEG Markdown Highlight's, so themes look the same.
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct HighlightMapperTests {
    /// The source text of each span, by element name.
    func spans(_ text: String, options: MarkdownDocumentModel.Options = .init()) -> [String: [String]] {
        let model = MarkdownDocumentModel(text, options: options)
        let source = text as NSString
        var result: [String: [String]] = [:]
        for (type, list) in model.highlights.spans.enumerated() where !list.isEmpty {
            result[ThemeStyle.elementNames[type]] = list.map {
                source.substring(with: NSRange(location: $0.pos, length: $0.end - $0.pos))
            }
        }
        return result
    }

    @Test func headersCoverTheirLinesAndLineBreak() {
        let s = spans("# One\n\nSetext\n===\n\n## Two ##\n\n###### Six")
        #expect(s["H1"] == ["# One\n", "Setext\n===\n"])
        #expect(s["H2"] == ["## Two ##\n"])
        #expect(s["H6"] == ["###### Six"])
    }

    @Test func emphasisAndStrongIncludeTheirMarkers() {
        let s = spans("*a* _b_ **c** __d__ ***e*** **f *g* h**\n")
        #expect(s["EMPH"] == ["*a*", "_b_", "***e***", "*g*"])
        // cmark gives the nested emphasis and strong of ***e*** one range.
        #expect(s["STRONG"] == ["**c**", "__d__", "***e***", "**f *g* h**"])
    }

    @Test func code() {
        let s = spans("Use `x` and `` a`b ``.\n\n```swift\nlet x = 1\n```\n\n    indented\n    more\n\nText\n")
        #expect(s["CODE"] == ["`x`", "`` a`b ``", "```swift\nlet x = 1\n```"])
        #expect(s["VERBATIM"] == ["    indented\n    more\n"])
    }

    @Test func blockQuoteMarkersOnly() {
        let s = spans("> one\n> > two\nlazy\n")
        #expect(s["BLOCKQUOTE"] == ["> ", "> ", "> "])
    }

    @Test func linksImagesAndAutolinks() {
        let s = spans("[a](u) [b][r] ![c](i.png) <https://x.org> <me@x.org>\n\n[r]: https://r.org\n")
        #expect(s["LINK"] == ["[a](u)", "[b][r]"])
        #expect(s["IMAGE"] == ["![c](i.png)"])
        #expect(s["AUTO_LINK_URL"] == ["<https://x.org>"])
        #expect(s["AUTO_LINK_EMAIL"] == ["<me@x.org>"])
    }

    @Test func htmlAndRules() {
        let s = spans("<div>\nblock\n</div>\n\nInline <b>x</b>.\n\n---\n")
        #expect(s["HTMLBLOCK"] == ["<div>\nblock\n</div>"])
        #expect(s["HTML"] == ["<b>", "</b>"])
        #expect(s["HRULE"] == ["---"])
    }

    @Test func positionsAreUTF16() {
        let s = spans("😀 *é*\n")
        #expect(s["EMPH"] == ["*é*"])
    }

    /// A header inside a block quote is colored; PEG reported an inverted
    /// span for it, which the editor skipped.
    @Test func headerInBlockQuote() {
        #expect(spans("> ## Quoted\n")["H2"] == ["## Quoted\n"])
    }

    @Test func listMarkers() {
        let s = spans("- a\n- b\n\n* c\n\n1. d\n2) e\n\n10. f\n\n> + quoted\n")
        #expect(s["LIST_BULLET"] == ["-", "-", "*", "+"])
        #expect(s["LIST_ENUMERATOR"] == ["1.", "2)", "10."])
    }

    @Test func referenceDefinitions() {
        let text = """
            [a]: https://a.org "Title"
            [b]: <https://b.org/with space>
            Text right after definitions.

            Text first,
            [c]: https://c.org is text here.

            - [d]: https://d.org

            > [e]: https://e.org

            [^1]: A footnote isn't a reference.

                [f]: https://f.org in code
            """
        #expect(spans(text)["REFERENCE"] == [
            #"[a]: https://a.org "Title""#, "[b]: <https://b.org/with space>",
            "[d]: https://d.org", "[e]: https://e.org",
        ])
    }

    @Test func entitiesOutsideCodeAndHTML() {
        let s = spans("&copy; &#169; &#x2603; &nope; `&amp;` <span title=\"&amp;\">x</span>\n\n# A &amp; B\n\n| &lt; |\n|---|\n")
        #expect(s["HTML_ENTITY"] == ["&copy;", "&#169;", "&#x2603;", "&nope;", "&amp;", "&lt;"])
    }

    @Test func comments() {
        let s = spans("<!-- block -->\n\nInline <!-- note --> text.\n")
        #expect(s["COMMENT"] == ["<!-- block -->", "<!-- note -->"])
        #expect(s["HTMLBLOCK"] == ["<!-- block -->"])
    }

    /// Footnotes (FR-27): PEG defined NOTE but never produced it. As in
    /// GFM, a reference without a definition is plain text.
    @Test func footnotes() {
        let s = spans("A note[^1] and[^long-label] and[^undefined].\n\n[^1]: The note.\n\n[^long-label]: **Formatted**.\n\n`[^code]` and [^ spaced].\n")
        #expect(s["NOTE"] == ["[^1]", "[^long-label]", "[^1]:", "[^long-label]:"])
        #expect(s["STRONG"] == ["**Formatted**"])    // definitions are Markdown
    }

    /// New types (FR-23, FR-19): each only with its setting on.
    @Test func mathHighlightAndSuperscript() {
        let text = "$x_1$ and $$y$$, ==marked== and == spaced ==, x^2 and 10^(-6). `==code== x^2`\n"
        let off = spans(text)
        #expect(off["MATH"] == nil && off["HIGHLIGHT"] == nil && off["SUPERSCRIPT"] == nil)
        let on = spans(text, options: .init(math: true, inlineDollar: true,
                                            highlight: true, superscript: true))
        #expect(on["MATH"] == ["$x_1$", "$$y$$"])
        #expect(on["HIGHLIGHT"] == ["==marked=="])
        #expect(on["SUPERSCRIPT"] == ["^2", "^(-6)"])
    }

    /// Links carry their address, for clickable links in the editor.
    @Test func linkAddresses() {
        let model = MarkdownDocumentModel("[a](https://a.org) <https://b.org> <me@c.org>\n",
                                          options: .init())
        func addresses(_ name: String) -> [String?] {
            model.highlights.spans[ThemeStyle.elementNames.firstIndex(of: name)!].map(\.address)
        }
        #expect(addresses("LINK") == ["https://a.org"])
        #expect(addresses("AUTO_LINK_URL") == ["https://b.org"])
        #expect(addresses("AUTO_LINK_EMAIL") == ["me@c.org"])    // the editor adds mailto:
    }
}

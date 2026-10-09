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
    func spans(_ text: String) -> [String: [String]] {
        let model = MarkdownDocumentModel(text, options: .init())
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
}

//
//  HTMLToMarkdownTests.swift
//  MacDownKitTests
//
//  Converting pasted HTML to Markdown (paste intent, FR-9 to FR-21).
//

import Foundation
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

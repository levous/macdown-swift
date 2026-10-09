//
//  MarkdownDocumentModelTests.swift
//  MacDownKitTests
//

import CHoedown
import Foundation
import Testing
@testable import MacDownKit

@Suite struct MarkdownDocumentModelTests {
    /// The model is built off the main actor and handed back (F6: the
    /// swift-markdown tree itself can't cross; the model can).
    @Test func buildsInADetachedTask() async {
        let source = "# Title\n\nText.\n"
        let model = await Task.detached {
            MarkdownDocumentModel(source, options: .init())
        }.value
        #expect(model.source == source)
        #expect(model.blocks.map(\.kind) == [.heading(level: 1), .paragraph])
    }

    @Test func blocksPointIntoTheEditorText() throws {
        let source = "# Tïtle 😀\n\n> Quote\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n"
        let model = MarkdownDocumentModel(source, options: .init())
        let text = source as NSString
        let heading = try #require(model.blocks.first)
        #expect(text.substring(with: heading.range) == "# Tïtle 😀")
        #expect(heading.lines == 1...1)
        let code = try #require(model.blocks.first { $0.kind == .codeBlock })
        #expect(code.lines == 8...10)
        #expect(text.substring(with: code.range).hasPrefix("```swift"))
        #expect(model.blocks.map(\.kind) == [
            .heading(level: 1), .blockQuote, .paragraph, .list, .listItem, .paragraph,
            .listItem, .paragraph, .codeBlock,
        ])
    }

    @Test func frontMatterIsNotABlock() {
        let source = "---\ntitle: Notes\n---\n\n# Body\n"
        let model = MarkdownDocumentModel(source, options: .init())
        #expect(model.frontMatter?.object["title"] == .string("Notes"))
        #expect(model.blocks.map(\.kind) == [.heading(level: 1)])
        #expect(model.blocks.first?.lines == 5...5)
    }

    @Test func mathIsProtectedOnlyWhenOn() {
        let source = "$$a_1 * b_2$$\n"
        #expect(MarkdownDocumentModel(source, options: .init(math: true)).math.count == 1)
        #expect(MarkdownDocumentModel(source, options: .init()).math.isEmpty)
        // Math ranges are UTF-16, ready for the editor.
        let model = MarkdownDocumentModel("é $x_1$\n", options: .init(math: true, inlineDollar: true))
        #expect(model.math == [NSRange(location: 2, length: 5)])
    }

    @Test func optionsFollowParseSettings() {
        var settings = ParseSettings()
        #expect(MarkdownDocumentModel.Options(settings) == .init())
        settings.extensionFlags = HOEDOWN_EXT_MATH.rawValue | HOEDOWN_EXT_MATH_EXPLICIT.rawValue
        settings.smartyPants = true
        #expect(MarkdownDocumentModel.Options(settings)
                == .init(math: true, inlineDollar: true, smartPunctuation: true))
    }

    @Test(arguments: try Corpus.all())
    func everyCorpusBlockIsInTheText(_ document: Corpus.Document) {
        let model = MarkdownDocumentModel(document.text, options: .init(math: true, inlineDollar: true))
        let length = (document.text as NSString).length
        #expect(!model.blocks.isEmpty)
        for block in model.blocks {
            #expect(NSMaxRange(block.range) <= length)
            #expect(block.lines.lowerBound >= 1)
        }
    }
}

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

/// The hidden engine setting routes parses through the model (FR-2).
@MainActor @Suite struct RendererEngineTests {
    @Test func renderSettingsCarryTheEngine() throws {
        let suite = "MacDownTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.renderSettings.parse.engine == .hoedown)
        preferences.markdownEngine = .swiftMarkdown
        #expect(preferences.renderSettings.parse.engine == .swiftMarkdown)
    }

    @Test func swiftMarkdownBuildsTheModel() async {
        let renderer = Renderer()
        var settings = ParseSettings()
        renderer.parseNow("# A\n", settings: settings)
        #expect(renderer.model == nil)

        settings.engine = .swiftMarkdown
        renderer.parseNow("# A\n", settings: settings)
        #expect(renderer.model?.blocks.map(\.kind) == [.heading(level: 1)])
        #expect(renderer.result.body.contains("<h1"))    // HTML is still hoedown's

        await withCheckedContinuation { done in
            renderer.parse("# B\n\nText\n", settings: settings) { done.resume() }
        }
        #expect(renderer.model?.source == "# B\n\nText\n")
        settings.engine = .hoedown
        renderer.parseNow("# A\n", settings: settings)
        #expect(renderer.model == nil)
    }

    /// Only the newest of several background parses lands.
    @Test func stalePassesAreDiscarded() async {
        let renderer = Renderer()
        var settings = ParseSettings()
        settings.engine = .swiftMarkdown
        var completions = 0
        renderer.parse(Corpus.generated(lines: 5_000), settings: settings) { completions += 1 }
        await withCheckedContinuation { done in
            renderer.parse("# Latest\n", settings: settings) { completions += 1; done.resume() }
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(completions == 1)
        #expect(renderer.model?.source == "# Latest\n")
        #expect(renderer.result.body.contains("Latest"))
    }
}

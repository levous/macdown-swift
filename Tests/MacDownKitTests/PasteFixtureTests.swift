//
//  PasteFixtureTests.swift
//  MacDownKitTests
//
//  Clipboard fixtures for pasting formatted text (Resources/Paste).
//

import Foundation
import Testing
@testable import MacDownKit

@MainActor @Suite struct PasteFixtureTests {
    static var directory: URL {
        Bundle.module.url(forResource: "Paste", withExtension: nil,
                          subdirectory: "Resources")!
    }

    /// The sample copied from each source app has every construct the
    /// converter handles.
    @Test func sampleCoversEveryConstruct() throws {
        let text = try String(contentsOf: Self.directory.appendingPathComponent("sample.md"),
                              encoding: .utf8)
        let body = MarkdownDocumentModel(text, options: .init()).body
        for markup in ["<h1", "<h2", "<h3", "<strong>", "<em>", "<del>", "<code>",
                       #"<code class="language-swift">"#,
                       #"href="https://example.com/"#, #"href="../notes/next.html""#,
                       ##"href="#lists""##, "<img ", "<ul>", "<ol start=\"3\">",
                       "type=\"checkbox\"", "<blockquote>", "<hr>", "<table>",
                       "colspan=", "rowspan="] {
            #expect(body.contains(markup), "missing \(markup)")
        }
    }
}

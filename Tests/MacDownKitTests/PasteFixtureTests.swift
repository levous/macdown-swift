//
//  PasteFixtureTests.swift
//  MacDownKitTests
//
//  Clipboard fixtures for pasting formatted text (Resources/Paste).
//

import AppKit
import Testing
@testable import MacDownKit

/// A clipboard capture (`Paste/<source>/`): one file per pasteboard type,
/// listed in `manifest.json`, and the Markdown a paste should produce.
struct PasteFixture: CustomTestStringConvertible, Sendable {
    let name: String
    /// Pasteboard type identifier → data.
    let types: [String: Data]
    /// `expected.md`, if the fixture has one.
    let expected: String?
    let synthetic: Bool

    var testDescription: String { name }

    func data(_ type: String) -> Data? { types[type] }
    func string(_ type: String) -> String? {
        types[type].map { String(decoding: $0, as: UTF8.self) }
    }
    var html: String? { string("public.html") }
    var rtf: Data? { data("public.rtf") }
    var plainText: String? { string("public.utf8-plain-text") }
    var sourceURL: URL? {
        (string("org.chromium.source-url") ?? string("public.url")).flatMap(URL.init(string:))
    }

    static var directory: URL {
        Bundle.module.url(forResource: "Paste", withExtension: nil,
                          subdirectory: "Resources")!
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable { let type: String; let file: String }
        let source: String
        let types: [Entry]
        let synthetic: Bool?
    }

    static func load(_ name: String) throws -> PasteFixture {
        let folder = directory.appendingPathComponent(name)
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        var types: [String: Data] = [:]
        for entry in manifest.types {
            types[entry.type] = try Data(contentsOf: folder.appendingPathComponent(entry.file))
        }
        let expected = try? String(contentsOf: folder.appendingPathComponent("expected.md"),
                                   encoding: .utf8)
        return PasteFixture(name: name, types: types, expected: expected,
                            synthetic: manifest.synthetic ?? false)
    }

    /// Every fixture folder, in name order.
    static func all() throws -> [PasteFixture] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted().map(load)
    }
}

@MainActor @Suite struct PasteFixtureTests {
    static var directory: URL { PasteFixture.directory }

    @Test func fixturesLoad() throws {
        let fixtures = try PasteFixture.all()
        #expect(fixtures.map(\.name).contains("synthetic-google-docs"))
        for fixture in fixtures {
            #expect(fixture.expected != nil, "\(fixture.name) has no expected.md")
            #expect(fixture.html != nil || fixture.rtf != nil, "\(fixture.name) has no HTML or RTF")
            #expect(fixture.plainText != nil, "\(fixture.name) has no plain text")
        }
        #expect(try PasteFixture.load("synthetic-browser").sourceURL?.absoluteString
                    == "https://example.com/guide/start.html")
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

/// Each source app's clipboard pastes as its expected Markdown (paste
/// intent, "Source quirks"): converted as the editor does, from HTML or
/// rich text, or as plain text when it's code.
@MainActor @Suite struct PasteFixtureConversionTests {
    /// What pasting the fixture inserts.
    static func pasted(_ fixture: PasteFixture) throws -> String {
        let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in fixture.types { item.setData(data, forType: .init(type)) }
        pasteboard.writeObjects([item])
        guard case .html(let html, let baseURL)? = PasteboardContent.read(from: pasteboard) else {
            return try #require(fixture.plainText)
        }
        var options = pasteTestOptions
        options.baseURL = baseURL
        guard let result = HTMLToMarkdown(options: options).convert(html), !result.isCode else {
            return try #require(fixture.plainText)
        }
        return result.markdown
    }

    @Test(arguments: ["synthetic-google-docs"])
    func fixture(_ name: String) throws {
        let fixture = try PasteFixture.load(name)
        #expect(try Self.pasted(fixture) == fixture.expected)
    }
}

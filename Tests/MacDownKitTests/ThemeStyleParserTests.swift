//
//  ThemeStyleParserTests.swift
//  MacDownKitTests
//
//  The Swift theme parser must read every stylesheet exactly as
//  pmh_styleparser.c did, errors included, checked against the C parser's
//  recorded results (EngineSnapshots).
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct ThemeStyleParserTests {
    static let themes: [URL] = {
        let directory = MPPaths.resourceBundle.url(forResource: "Themes", withExtension: nil)!
        return try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "style" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    @Test func allFifteenThemes() {
        #expect(Self.themes.count == 15)
    }

    @Test(arguments: themes)
    func matchesTheCParser(_ url: URL) throws {
        let stylesheet = try String(contentsOf: url, encoding: .utf8)
        let swift = ThemeStyle(parsing: stylesheet)
        #expect(themeDescription(swift) == (try EngineSnapshots.value("theme/" + url.lastPathComponent)))
        #expect(swift.errors.isEmpty)
        #expect(!swift.elements.isEmpty && !swift.editor.isEmpty)
    }

    /// Errors and the C parser's quirks, with CRLF line endings and a BOM.
    static let malformed = "\u{FEFF}" + """
            # A comment before any rule

            editor
            foreground: 112233
            background = #ignored after a comment marker
            caret: 0xabcdef
            unknown-attr :  some value   # trailing comment
            # comment inside a block

            editor
            foreground: 445566

            H1
            color: zz1122
            font-size: +4pt
            font-style: Bold, italic, , wavy,
            font-family:  Menlo
            no assignment here

            NOT_A_TYPE
            color: 000000

            H2

            EMPH
            color: 12345
            font-size: big

            STRONG
            foreground-color: -fffff
            background-color: 80ff0000
            """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test func malformedStylesheet() throws {
        let stylesheet = Self.malformed
        let swift = ThemeStyle(parsing: stylesheet)
        #expect(themeDescription(swift) == (try EngineSnapshots.value("theme/malformed")))
        #expect(swift.errors.count >= 7, "\(swift.errors)")
        // The later editor rule replaces the first.
        #expect(swift.editor == [.init(name: "foreground", value: .foregroundColor(
            .init(red: 0x44, green: 0x55, blue: 0x66, alpha: 255)))])
        // EMPH's attributes were all invalid, so it's left out.
        #expect(!swift.elements.contains { $0.element == "EMPH" })
    }

    /// Element names follow PEG Markdown Highlight's element types
    /// (pmh_element_type), then the types PEG didn't have.
    @Test func elementNamesFollowThePEGOrder() {
        #expect(ThemeStyle.elementNames == [
            "LINK", "AUTO_LINK_URL", "AUTO_LINK_EMAIL", "IMAGE", "CODE", "HTML", "HTML_ENTITY",
            "EMPH", "STRONG", "LIST_BULLET", "LIST_ENUMERATOR", "COMMENT", "H1", "H2", "H3", "H4",
            "H5", "H6", "BLOCKQUOTE", "VERBATIM", "HTMLBLOCK", "HRULE", "REFERENCE", "NOTE",
            "MATH", "HIGHLIGHT", "SUPERSCRIPT",
        ])
    }

    @Test func errorMessagesReadLikeTheHighlighters() {
        let style = ThemeStyle(parsing: "H1\ncolor: 12\n")
        #expect(style.errors.map(\.description) == [
            "(Line 2): Value '12' is not a valid color value: it should be a hexadecimal "
                + "number, 6 or 8 characters long.",
        ])
    }
}

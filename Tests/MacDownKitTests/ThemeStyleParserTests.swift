//
//  ThemeStyleParserTests.swift
//  MacDownKitTests
//
//  The Swift theme parser must read every stylesheet exactly as
//  pmh_styleparser.c does, errors included.
//

import CPegMarkdown
import Foundation
import Testing
@testable import MacDownKit

/// The C parser's result, in ThemeStyle's shape.
private func cStyle(_ stylesheet: String) -> ThemeStyle {
    final class Box { var errors: [ThemeStyle.ParseError] = [] }
    let box = Box()
    let callback: @convention(c) (UnsafeMutablePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void = {
        message, line, context in
        let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
        box.errors.append(.init(line: Int(line), message: String(cString: message!)))
    }
    let unmanaged = Unmanaged.passRetained(box)
    defer { unmanaged.release() }
    let collection = stylesheet.withCString {
        pmh_parse_styles(UnsafeMutablePointer(mutating: $0), callback, unmanaged.toOpaque())
    }!
    defer { pmh_free_style_collection(collection) }

    func attributes(_ list: UnsafeMutablePointer<pmh_style_attribute>?) -> [ThemeStyle.Attribute] {
        var result: [ThemeStyle.Attribute] = []
        var cursor = list
        while let attribute = cursor {
            let a = attribute.pointee, v = a.value.pointee
            func color() -> ThemeStyle.Color {
                let c = v.argb_color.pointee
                return .init(red: Int(c.red), green: Int(c.green), blue: Int(c.blue), alpha: Int(c.alpha))
            }
            let value: ThemeStyle.Value = switch a.type {
            case pmh_attr_type_foreground_color: .foregroundColor(color())
            case pmh_attr_type_background_color: .backgroundColor(color())
            case pmh_attr_type_caret_color: .caretColor(color())
            case pmh_attr_type_font_size_pt:
                .fontSize(points: Int(v.font_size.pointee.size_pt),
                          relative: v.font_size.pointee.is_relative)
            case pmh_attr_type_font_family: .fontFamily(String(cString: v.font_family))
            case pmh_attr_type_font_style:
                .fontStyle(italic: v.font_styles.pointee.italic, bold: v.font_styles.pointee.bold,
                           underlined: v.font_styles.pointee.underlined)
            default: .other(String(cString: v.string))
            }
            result.append(.init(name: String(cString: a.name), value: value))
            cursor = a.next
        }
        return result
    }

    var style = ThemeStyle()
    style.editor = attributes(collection.pointee.editor_styles)
    style.currentLine = attributes(collection.pointee.editor_current_line_styles)
    style.selection = attributes(collection.pointee.editor_selection_styles)
    for i in 0..<Int(pmh_NUM_LANG_TYPES) {
        guard let list = collection.pointee.element_styles[i] else { continue }
        let name = String(cString: pmh_element_name_from_type(list.pointee.lang_element_type))
        style.elements.append(.init(element: name, attributes: attributes(list)))
    }
    style.errors = box.errors
    return style
}

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
        #expect(swift == cStyle(stylesheet))
        #expect(swift.errors.isEmpty)
        #expect(!swift.elements.isEmpty && !swift.editor.isEmpty)
    }

    /// Errors and the C parser's quirks, with CRLF line endings and a BOM.
    @Test func malformedStylesheet() {
        let stylesheet = "\u{FEFF}" + """
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
        let swift = ThemeStyle(parsing: stylesheet)
        let c = cStyle(stylesheet)
        #expect(swift == c)
        #expect(swift.errors.count >= 7, "\(swift.errors)")
        // The later editor rule replaces the first.
        #expect(swift.editor == [.init(name: "foreground", value: .foregroundColor(
            .init(red: 0x44, green: 0x55, blue: 0x66, alpha: 255)))])
        // EMPH's attributes were all invalid, so it's left out.
        #expect(!swift.elements.contains { $0.element == "EMPH" })
    }

    @Test func errorMessagesReadLikeTheHighlighters() {
        let style = ThemeStyle(parsing: "H1\ncolor: 12\n")
        #expect(style.errors.map(\.description) == [
            "(Line 2): Value '12' is not a valid color value: it should be a hexadecimal "
                + "number, 6 or 8 characters long.",
        ])
    }
}

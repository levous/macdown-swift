//
//  ThemeStyleParser.swift
//  MacDownKit
//
//  Parses editor themes (`.style` files) — a Swift port of PEG Markdown
//  Highlight's pmh_styleparser.c, so the themes keep working once the C
//  library is gone (swift-markdown migration, Phase 2). Element names,
//  attributes, colors, font traits and error messages are the same, as are
//  the C parser's quirks: a rule's attributes come out in reverse order,
//  and a later `editor`, `editor-current-line` or `editor-selection` rule
//  replaces an earlier one.
//

import Foundation

public struct ThemeStyle: Sendable, Equatable {
    public struct Color: Sendable, Equatable {
        public var red, green, blue, alpha: Int
    }

    public enum Value: Sendable, Equatable {
        case foregroundColor(Color)
        case backgroundColor(Color)
        case caretColor(Color)
        case fontSize(points: Int, relative: Bool)
        case fontFamily(String)
        case fontStyle(italic: Bool, bold: Bool, underlined: Bool)
        /// An attribute the parser doesn't know, kept as its trimmed text.
        case other(String)
    }

    public struct Attribute: Sendable, Equatable {
        public var name: String
        public var value: Value
    }

    public struct ElementStyle: Sendable, Equatable {
        /// The element's PEG Markdown Highlight name, such as "EMPH" or "H1".
        public var element: String
        public var attributes: [Attribute]
    }

    public struct ParseError: Sendable, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "(Line \(line)): \(message)" }
    }

    public var editor: [Attribute] = []
    public var currentLine: [Attribute] = []
    public var selection: [Attribute] = []
    /// Element rules in file order. Rules whose attributes were all invalid
    /// are left out.
    public var elements: [ElementStyle] = []
    public var errors: [ParseError] = []

    /// The element names a rule may use.
    public static let elementNames: [String] = [
        "LINK", "AUTO_LINK_URL", "AUTO_LINK_EMAIL", "IMAGE", "CODE", "HTML",
        "HTML_ENTITY", "EMPH", "STRONG", "LIST_BULLET", "LIST_ENUMERATOR", "COMMENT",
        "H1", "H2", "H3", "H4", "H5", "H6", "BLOCKQUOTE", "VERBATIM", "HTMLBLOCK",
        "HRULE", "REFERENCE", "NOTE",
        // Not in PEG Markdown Highlight: math and the opt-in syntax.
        "MATH", "HIGHLIGHT", "SUPERSCRIPT",
    ]

    public init(parsing stylesheet: String) {
        var parser = Parser()
        parser.parse(stylesheet)
        self = parser.style
    }

    public init() {}
}

private struct Parser {
    var style = ThemeStyle()

    mutating func error(_ line: Int, _ message: String) {
        style.errors.append(.init(line: line, message: message))
    }

    // C's isspace, and the parser's own narrower whitespace for blank and
    // comment lines.
    static func isSpace(_ c: Character) -> Bool { " \t\n\r\u{0B}\u{0C}".contains(c) }
    static func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }
    static func isAssignment(_ c: Character) -> Bool { c == ":" || c == "=" }

    static func trim(_ s: Substring) -> String {
        String(s.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
    }

    struct Line { let number: Int; let text: Substring }

    mutating func parse(_ input: String) {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Blocks are runs of non-blank lines. Comment lines before a block
        // starts are dropped; inside one they're kept (and skipped later).
        var blocks: [[Line]] = []
        var current: [Line]?
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }    // as C's split, no final empty line
        for (i, line) in lines.enumerated() {
            let entry = Line(number: i + 1, text: line)
            if line.allSatisfy(Self.isBlank) {
                if let block = current { blocks.append(block); current = nil }
            } else if line.first(where: { !Self.isBlank($0) }) == "#" {
                current?.append(entry)
            } else if current == nil {
                current = [entry]
            } else {
                current!.append(entry)
            }
        }
        if let block = current { blocks.append(block) }

        for block in blocks {
            let header = block[0]
            let name = String(header.text.drop(while: Self.isSpace)
                .prefix { !Self.isSpace($0) && $0 != "#" && !Self.isAssignment($0) })
            if block.count == 1 {
                error(header.number, "No style attributes defined for style rule '\(name)'")
            }
            var raw: [(name: String, value: Substring, line: Int)] = []
            for line in block.dropFirst()
            where line.text.first(where: { !Self.isBlank($0) }) != "#" {
                if let attribute = parseAttributeLine(line) { raw.append(attribute) }
            }
            if !raw.isEmpty { add(rule: name, line: header.number, raw: raw) }
        }
    }

    mutating func parseAttributeLine(_ line: Line) -> (name: String, value: Substring, line: Int)? {
        let text = line.text
        let afterSpace = text.drop(while: Self.isSpace)
        var name = afterSpace.prefix { $0 != "#" && !Self.isAssignment($0) }
        while let last = name.last, Self.isSpace(last) { name = name.dropLast() }
        // The first assignment operator at or after the name's end.
        let rest = text[name.endIndex...]
        guard let op = rest.firstIndex(where: Self.isAssignment) else {
            error(line.number, "Invalid attribute definition: str does not contain an "
                  + "assignment operator (':' or '='): '\(text)'")
            return nil
        }
        let value = text[text.index(after: op)...].prefix { $0 != "#" }
        return (String(name), value, line.number)
    }

    mutating func add(rule: String, line: Int, raw: [(name: String, value: Substring, line: Int)]) {
        let attributes = interpret(raw)
        switch rule {
        case _ where ThemeStyle.elementNames.contains(rule):
            if !attributes.isEmpty {
                style.elements.append(.init(element: rule, attributes: attributes))
            }
        case "editor": style.editor = attributes
        case "editor-current-line": style.currentLine = attributes
        case "editor-selection": style.selection = attributes
        default:
            error(line, "Style rule '\(rule)' is not a language element type name or "
                  + "one of the following: 'editor', 'editor-current-line', 'editor-selection'")
        }
    }

    mutating func interpret(_ raw: [(name: String, value: Substring, line: Int)]) -> [ThemeStyle.Attribute] {
        var attributes: [ThemeStyle.Attribute] = []
        for (name, value, line) in raw {
            let parsed: ThemeStyle.Value?
            switch name {
            case "color", "foreground", "foreground-color":
                parsed = color(Self.trim(value), line: line).map { .foregroundColor($0) }
            case "background", "background-color":
                parsed = color(Self.trim(value), line: line).map { .backgroundColor($0) }
            case "caret", "caret-color":
                parsed = color(Self.trim(value), line: line).map { .caretColor($0) }
            case "font-size":
                let trimmed = Self.trim(value)
                if let points = Self.strtol(value) {
                    parsed = .fontSize(points: points,
                                       relative: trimmed.first == "+" || trimmed.first == "-")
                } else {
                    error(line, "Value '\(value)' is invalid for attribute '\(name)'")
                    parsed = nil
                }
            case "font-family":
                parsed = .fontFamily(Self.trim(value))
            case "font-style":
                var italic = false, bold = false, underlined = false
                for part in value.split(separator: ",", omittingEmptySubsequences: false)
                where !(part.isEmpty && part.endIndex == value.endIndex) {
                    switch Self.trim(part).lowercased() {
                    case "italic": italic = true
                    case "bold": bold = true
                    case "underlined": underlined = true
                    case let other:
                        error(line, "Value '\(other)' is invalid for attribute '\(name)'")
                    }
                }
                parsed = .fontStyle(italic: italic, bold: bold, underlined: underlined)
            default:
                parsed = .other(Self.trim(value))
            }
            // The C parser prepends to a linked list.
            if let parsed { attributes.insert(.init(name: name, value: parsed), at: 0) }
        }
        return attributes
    }

    mutating func color(_ text: String, line: Int) -> ThemeStyle.Color? {
        let length = text.utf8.count
        guard length == 6 || length == 8 else {
            error(line, "Value '\(text)' is not a valid color value: it should be a "
                  + "hexadecimal number, 6 or 8 characters long.")
            return nil
        }
        let (number, end) = Self.strtoll(text, base: 16)
        guard end == text.endIndex else {
            error(line, "Value '\(text)' is not a valid color value: the character "
                  + "'\(text[end])' is invalid. The color value should be a hexadecimal "
                  + "number, 6 or 8 characters long.")
            return nil
        }
        let hex = UInt64(bitPattern: number)
        return .init(red: Int((hex >> 16) & 0xFF), green: Int((hex >> 8) & 0xFF),
                     blue: Int(hex & 0xFF), alpha: length == 8 ? Int((hex >> 24) & 0xFF) : 255)
    }

    /// C's strtoll: leading whitespace, a sign, "0x" for base 16, digits.
    /// Returns the value and where parsing stopped (the start if there
    /// were no digits).
    static func strtoll(_ text: String, base: Int) -> (Int64, String.Index) {
        var index = text.startIndex
        while index < text.endIndex, isSpace(text[index]) { index = text.index(after: index) }
        var negative = false
        if index < text.endIndex, text[index] == "+" || text[index] == "-" {
            negative = text[index] == "-"
            index = text.index(after: index)
        }
        func digit(_ i: String.Index) -> Int? {
            i < text.endIndex ? text[i].hexDigitValue.flatMap { $0 < base ? $0 : nil } : nil
        }
        if base == 16, index < text.endIndex, text[index] == "0" {
            let x = text.index(after: index)
            if x < text.endIndex, text[x] == "x" || text[x] == "X",
               digit(text.index(after: x)) != nil {
                index = text.index(after: x)
            }
        }
        var value: Int64 = 0
        var any = false
        while let d = digit(index) {
            value = value &* Int64(base) &+ Int64(d)
            any = true
            index = text.index(after: index)
        }
        guard any else { return (0, text.startIndex) }
        return (negative ? -value : value, index)
    }

    static func strtol(_ text: Substring) -> Int? {
        let (value, end) = strtoll(String(text), base: 10)
        return end == String(text).startIndex ? nil : Int(Int32(truncatingIfNeeded: value))
    }
}

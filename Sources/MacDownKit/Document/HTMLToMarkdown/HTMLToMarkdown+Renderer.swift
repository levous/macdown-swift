//
//  HTMLToMarkdown+Renderer.swift
//  MacDownKit
//
//  Blocks of inline runs as Markdown text.
//

import Foundation

extension HTMLToMarkdown {
    struct Renderer {
        let options: Options

        /// The blocks separated by one blank line (FR-21); a lone paragraph
        /// has no newline, to be inserted inline (FR-9).
        func render(_ blocks: [Block]) -> Result {
            let rendered = blocks.map { (block: $0, text: render($0).trimmingCharacters(in: .newlines)) }
                .filter { !$0.text.isEmpty }
            let markdown = rendered.map(\.text).joined(separator: "\n\n")
            if rendered.count == 1, case .paragraph = rendered[0].block {
                return Result(markdown: markdown, isInline: true)
            }
            return Result(markdown: markdown.isEmpty ? "" : markdown + "\n", isInline: false)
        }

        func render(_ block: Block) -> String {
            switch block {
            case .paragraph(let inlines):
                return render(inlines)
            case .heading(let level, let inlines):
                var content = render(inlines, atLineStart: false)
                // A trailing run of # after a space would close the heading.
                let hashes = content.reversed().prefix(while: { $0 == "#" }).count
                if hashes > 0, content.dropLast(hashes).last == " " {
                    content.insert("\\", at: content.index(content.endIndex, offsetBy: -hashes))
                }
                return String(repeating: "#", count: level) + " " + content
            }
        }

        // MARK: - Inline content

        /// Emphasis, outermost first (FR-11).
        enum Emphasis: CaseIterable {
            case strike, bold, italic

            var marker: String {
                switch self {
                case .strike: "~~"
                case .bold: "**"
                case .italic: "*"
                }
            }

            func isOn(_ style: TextStyle) -> Bool {
                switch self {
                case .strike: style.strike
                case .bold: style.bold
                case .italic: style.italic
                }
            }

            func set(_ on: Bool, in style: inout TextStyle) {
                switch self {
                case .strike: style.strike = on
                case .bold: style.bold = on
                case .italic: style.italic = on
                }
            }
        }

        func render(_ inlines: [Inline], atLineStart: Bool = true) -> String {
            var lineStart = atLineStart
            return render(Self.joiningSpaces(inlines), levels: Emphasis.allCases[...], lineStart: &lineStart)
        }

        /// Runs grouped by each emphasis in turn: a group with the emphasis on
        /// is wrapped in its marker, with the whitespace at its edges moved
        /// outside.
        private func render(_ inlines: [Inline], levels: ArraySlice<Emphasis>,
                            lineStart: inout Bool) -> String {
            guard let level = levels.first else {
                var output = ""
                for inline in inlines {
                    switch inline {
                    case .text(let text, _):
                        output += Self.escape(text, atLineStart: lineStart)
                        lineStart = false
                    case .lineBreak:
                        output += "\\\n"
                        lineStart = true
                    }
                }
                return output
            }
            var output = ""
            for group in Self.groups(inlines, by: level) {
                guard group.on else {
                    output += render(group.inlines, levels: levels.dropFirst(), lineStart: &lineStart)
                    continue
                }
                var inner = false
                let content = render(group.inlines, levels: levels.dropFirst(), lineStart: &inner)
                let leading = content.prefix(while: { $0 == " " })
                let trailing = content.reversed().prefix(while: { $0 == " " })
                var core = content.dropFirst(leading.count).dropLast(trailing.count)
                guard !core.isEmpty else {
                    output += content
                    continue
                }
                // A backslash just before the closing marker would escape it.
                let backslashes = core.reversed().prefix(while: { $0 == "\\" }).count
                if backslashes % 2 == 1 { core += "\\" }
                output += leading + level.marker + core + level.marker + String(trailing)
                lineStart = false
            }
            return output
        }

        /// Consecutive inlines with the same setting of `style`; a line break
        /// is a group of its own, so markers close before it.
        private static func groups(_ inlines: [Inline], by emphasis: Emphasis)
            -> [(on: Bool, inlines: [Inline])] {
            var groups: [(on: Bool, inlines: [Inline])] = []
            for inline in inlines {
                let on: Bool
                switch inline {
                case .text(_, let textStyle): on = emphasis.isOn(textStyle)
                case .lineBreak:
                    groups.append((false, [inline]))
                    continue
                }
                if let last = groups.last, last.on == on, last.inlines.last != .lineBreak {
                    groups[groups.count - 1].inlines.append(inline)
                } else {
                    groups.append((on, [inline]))
                }
            }
            return groups
        }

        /// Whitespace between two runs takes the emphasis they share, so
        /// `**one** **two**` is written `**one two**`.
        static func joiningSpaces(_ inlines: [Inline]) -> [Inline] {
            var result = inlines
            func style(near index: Int, step: Int) -> TextStyle? {
                var index = index + step
                while result.indices.contains(index) {
                    guard case .text(let text, let style) = result[index] else { return nil }
                    if !text.allSatisfy(\.isWhitespace) { return style }
                    index += step
                }
                return nil
            }
            for index in result.indices {
                guard case .text(let text, var textStyle) = result[index], text.allSatisfy(\.isWhitespace)
                else { continue }
                let before = style(near: index, step: -1), after = style(near: index, step: 1)
                for emphasis in Emphasis.allCases {
                    emphasis.set(before.map(emphasis.isOn) == true && after.map(emphasis.isOn) == true,
                                 in: &textStyle)
                }
                result[index] = .text(text, textStyle)
            }
            return result
        }

        // MARK: - Escaping

        static let asciiPunctuation = Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)
        private static let blockStart = try! NSRegularExpression(
            pattern: #"^(?:#{1,6}(?:\s|$)|>|[-+](?:\s|$)|(?:=+|-+)\s*$)"#)
        private static let orderedListStart = try! NSRegularExpression(pattern: #"^\d{1,9}([.)])(?:\s|$)"#)
        private static let entity = try! NSRegularExpression(pattern: #"^&(?:#[0-9xX]|[A-Za-z][A-Za-z0-9]*;)"#)

        /// Text with the characters escaped that would otherwise be read as
        /// Markdown, and only those (FR-20). `atLineStart` also escapes what
        /// would start a block: a heading, quote, list item or rule.
        static func escape(_ text: String, atLineStart: Bool, inTable: Bool = false) -> String {
            let characters = Array(text)
            var escapedIndices: Set<Int> = []
            if atLineStart {
                let range = NSRange(text.startIndex..., in: text)
                if blockStart.firstMatch(in: text, range: range) != nil {
                    escapedIndices.insert(0)
                } else if let match = orderedListStart.firstMatch(in: text, range: range),
                          let marker = Range(match.range(at: 1), in: text) {
                    escapedIndices.insert(text.distance(from: text.startIndex, to: marker.lowerBound))
                }
            }
            var output = ""
            for (index, character) in characters.enumerated() {
                let previous = index > 0 ? characters[index - 1] : nil
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                var escapes = escapedIndices.contains(index)
                switch character {
                case "`", "*", "[", "]", "~":
                    escapes = true
                case "_":
                    // Inside a word, `_` never makes emphasis.
                    let inWord = previous.map { $0.isLetter || $0.isNumber } == true
                        && next.map { $0.isLetter || $0.isNumber } == true
                    if !inWord { escapes = true }
                case "\\":
                    if let next, asciiPunctuation.contains(next) { escapes = true }
                case "<":
                    if let next, next.isLetter || "/!?".contains(next) { escapes = true }
                case "&":
                    let rest = String(characters[index...].prefix(34))
                    if entity.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
                        escapes = true
                    }
                case "|":
                    if inTable { escapes = true }
                default:
                    break
                }
                if escapes { output.append("\\") }
                output.append(character)
            }
            return output
        }
    }
}

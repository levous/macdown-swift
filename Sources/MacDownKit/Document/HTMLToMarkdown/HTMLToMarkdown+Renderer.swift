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
            }
        }

        func render(_ inlines: [Inline]) -> String {
            var output = ""
            for inline in inlines {
                switch inline {
                case .text(let text, _):
                    output += Self.escape(text, atLineStart: output.isEmpty)
                }
            }
            return output
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

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

        /// The blocks separated by one blank line; a lone paragraph
        /// has no newline, to be inserted inline.
        func render(_ blocks: [Block]) -> Result {
            let rendered = renderedBlocks(blocks)
            let markdown = rendered.map(\.text).joined(separator: "\n\n")
            if rendered.count == 1, case .paragraph = rendered[0].block {
                return Result(markdown: markdown, isInline: true)
            }
            return Result(markdown: markdown.isEmpty ? "" : markdown + "\n", isInline: false)
        }

        /// Each block's Markdown, without edge newlines; empty ones are
        /// dropped. A list right after another of the same kind uses the
        /// other marker, so the two don't merge.
        func renderedBlocks(_ blocks: [Block]) -> [(block: Block, text: String)] {
            var result: [(block: Block, text: String)] = []
            var alternate = false
            for block in blocks {
                if case .list(let list) = block, case .list(let previous)? = result.last?.block,
                   previous.ordered == list.ordered {
                    alternate.toggle()
                } else {
                    alternate = false
                }
                let text = render(block, alternate: alternate).trimmingCharacters(in: .newlines)
                if !text.isEmpty { result.append((block, text)) }
            }
            return result
        }

        func render(_ block: Block, alternate: Bool = false) -> String {
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
            case .code(let language, let text):
                let fence = String(repeating: "`", count: max(3, Self.longestRun(of: "`", in: text) + 1))
                return fence + (language ?? "") + "\n" + text + "\n" + fence
            case .list(let list):
                return render(list, alternate: alternate)
            case .quote(let blocks):
                return renderedBlocks(blocks).map(\.text).joined(separator: "\n\n")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? ">" : "> " + $0 }
                    .joined(separator: "\n")
            case .rule:
                // `---` would read as a list item to someone using `-` bullets.
                return options.listMarker == "-" ? "***" : "---"
            case .table(let table):
                return render(table)
            }
        }

        // MARK: - Lists

        /// A list with the writer's marker. Items are separated by
        /// blank lines when any holds more than one block; an item's lines
        /// after the first are indented by the indent setting, or to the
        /// content column when the marker is wider.
        func render(_ list: List, alternate: Bool) -> String {
            let loose = list.items.contains { $0.spaced || $0.blocks.filter { !$0.isList }.count > 1 }
            var items: [String] = []
            for (offset, item) in list.items.enumerated() {
                let marker = list.ordered
                    ? "\(list.start + offset)\(alternate ? ")" : ".")"
                    : alternate ? (options.listMarker == "*" ? "-" : "*") : options.listMarker
                let indent = childIndent(contentColumn: marker.count + 1)
                var content = ""
                for (index, entry) in renderedBlocks(item.blocks).enumerated() {
                    if index > 0 {
                        // A sublist follows its paragraph directly in a tight
                        // list, except a numbered one not starting at 1, which
                        // can't interrupt a paragraph.
                        var directly = !loose
                        if case .list(let sublist) = entry.block {
                            if sublist.ordered, sublist.start != 1 { directly = false }
                        } else {
                            directly = false
                        }
                        content += directly ? "\n" : "\n\n"
                    }
                    content += entry.text
                }
                let task = item.task.map { $0 ? "[x] " : "[ ] " } ?? ""
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                items.append(lines.enumerated().map { index, line in
                    index == 0 ? marker + " " + task + line : line.isEmpty ? "" : indent + line
                }.joined(separator: "\n"))
            }
            return items.joined(separator: loose ? "\n\n" : "\n")
        }

        /// The indent setting, or spaces to `contentColumn` if it's wider.
        func childIndent(contentColumn: Int) -> String {
            let width = options.indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            return width >= contentColumn ? options.indent : String(repeating: " ", count: contentColumn)
        }

        // MARK: - Inline content

        /// Emphasis, outermost first.
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

        /// Inline content: links outermost, so a link is never split, then
        /// emphasis, then code.
        func render(_ inlines: [Inline], atLineStart: Bool = true) -> String {
            var lineStart = atLineStart
            var output = ""
            for group in Self.linkGroups(Self.joiningSpaces(inlines)) {
                guard let link = group.link else {
                    output += render(group.inlines, levels: Emphasis.allCases, lineStart: &lineStart)
                    continue
                }
                var inner = false
                let content = render(group.inlines, levels: Emphasis.allCases, lineStart: &inner)
                let leading = content.prefix(while: { $0 == " " })
                let trailing = content.reversed().prefix(while: { $0 == " " })
                let text = content.dropFirst(leading.count).dropLast(trailing.count)
                output += leading
                if !text.isEmpty {
                    output += Self.link(link, text: String(text), plainText: Self.plainText(group.inlines))
                    lineStart = false
                }
                output += String(trailing)
            }
            return output
        }

        /// `[text](url "title")`, or `<url>` when the text is the URL.
        static func link(_ link: Link, text: String, plainText: String) -> String {
            let plain = plainText.trimmingCharacters(in: .whitespaces)
            if link.title == nil, !link.url.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) {
                if plain == link.url, link.url.contains(":") { return "<\(link.url)>" }
                if link.url.lowercased() == "mailto:" + plain.lowercased() { return "<\(plain)>" }
            }
            return "[\(text)](\(destination(link.url, title: link.title)))"
        }

        /// `![alt](src "title")`.
        static func image(_ image: Image) -> String {
            "![\(escape(image.alt, atLineStart: false))](\(destination(image.source, title: image.title)))"
        }

        /// A link destination and title: spaces encoded, and wrapped in `<>`
        /// when its parentheses don't balance.
        static func destination(_ url: String, title: String?) -> String {
            var destination = url.replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
            var depth = 0, balanced = true
            for character in destination {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1; if depth < 0 { balanced = false } }
            }
            if !balanced || depth != 0 { destination = "<\(destination)>" }
            if let title {
                let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                destination += " \"\(escaped)\""
            }
            return destination
        }

        static func plainText(_ inlines: [Inline]) -> String {
            inlines.map {
                switch $0 {
                case .text(let text, _): text
                case .image(let image, _): image.alt
                case .lineBreak: " "
                }
            }.joined()
        }

        /// Consecutive inlines in the same link; a line break is a group of
        /// its own.
        private static func linkGroups(_ inlines: [Inline]) -> [(link: Link?, inlines: [Inline])] {
            var groups: [(link: Link?, inlines: [Inline])] = []
            for inline in inlines {
                let link: Link?
                switch inline {
                case .text(_, let style), .image(_, let style): link = style.link
                case .lineBreak: link = nil
                }
                if let last = groups.last, last.link == link, link == nil || inline != .lineBreak {
                    groups[groups.count - 1].inlines.append(inline)
                } else {
                    groups.append((link, [inline]))
                }
            }
            return groups
        }

        /// Inlines with their emphasis markers. Left to right, the emphasis
        /// whose run goes on furthest from each point is wrapped in its
        /// marker (whitespace at its edges moved outside), with the rest
        /// nested inside, so `*a **b** c*` stays nested rather than split.
        /// Text with none of `levels` on goes to `renderCode`.
        private func render(_ inlines: [Inline], levels: [Emphasis],
                            lineStart: inout Bool) -> String {
            func isOn(_ emphasis: Emphasis, _ inline: Inline) -> Bool {
                switch inline {
                case .text(_, let style), .image(_, let style): emphasis.isOn(style)
                case .lineBreak: false
                }
            }
            var output = ""
            var plain: [Inline] = []
            var index = 0
            while index < inlines.count {
                let runs = levels.map { emphasis in
                    (emphasis, inlines[index...].prefix { isOn(emphasis, $0) }.count)
                }
                guard let (level, length) = runs.max(by: { $0.1 < $1.1 }), length > 0 else {
                    plain.append(inlines[index])
                    index += 1
                    continue
                }
                output += renderCode(plain, lineStart: &lineStart)
                plain = []
                var inner = false
                let content = render(Array(inlines[index..<index + length]),
                                     levels: levels.filter { $0 != level }, lineStart: &inner)
                index += length
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
            return output + renderCode(plain, lineStart: &lineStart)
        }

        /// Monospace runs as code spans, the rest as escaped text.
        private func renderCode(_ inlines: [Inline], lineStart: inout Bool) -> String {
            var output = ""
            var code = ""
            func flushCode() {
                guard !code.isEmpty else { return }
                if code.allSatisfy({ $0 == " " }) {
                    output += code
                } else {
                    output += Self.codeSpan(code)
                    lineStart = false
                }
                code = ""
            }
            for inline in inlines {
                switch inline {
                case .text(let text, let style) where style.monospace:
                    code += text
                case .text(let text, _):
                    flushCode()
                    output += Self.escape(text, atLineStart: lineStart)
                    lineStart = false
                case .lineBreak:
                    flushCode()
                    output += "\\\n"
                    lineStart = true
                case .image(let image, _):
                    flushCode()
                    output += Self.image(image)
                    lineStart = false
                }
            }
            flushCode()
            return output
        }

        /// `content` between backtick runs longer than any inside it. Its
        /// spaces are kept: it's padded with a space on each side (which
        /// CommonMark removes) when it starts or ends with a backtick, or
        /// starts and ends with a space.
        static func codeSpan(_ content: String) -> String {
            let fence = String(repeating: "`", count: longestRun(of: "`", in: content) + 1)
            let pad = content.hasPrefix("`") || content.hasSuffix("`")
                || (content.hasPrefix(" ") && content.hasSuffix(" ")) ? " " : ""
            return fence + pad + content + pad + fence
        }

        static func longestRun(of character: Character, in text: String) -> Int {
            var longest = 0, current = 0
            for c in text {
                current = c == character ? current + 1 : 0
                longest = max(longest, current)
            }
            return longest
        }

        /// Whitespace between two runs takes the emphasis (and code) they
        /// share, so `**one** **two**` is written `**one two**`.
        static func joiningSpaces(_ inlines: [Inline]) -> [Inline] {
            var result = inlines
            func style(near index: Int, step: Int) -> TextStyle? {
                var index = index + step
                while result.indices.contains(index) {
                    switch result[index] {
                    case .text(let text, let style):
                        if !text.allSatisfy(\.isWhitespace) { return style }
                    case .image(_, let style):
                        return style
                    case .lineBreak:
                        return nil
                    }
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
                textStyle.monospace = before?.monospace == true && after?.monospace == true
                textStyle.link = before?.link == after?.link ? before?.link : nil
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
        /// Markdown, and only those. `atLineStart` also escapes what
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

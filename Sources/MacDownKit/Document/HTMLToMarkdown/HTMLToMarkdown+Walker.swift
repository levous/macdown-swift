//
//  HTMLToMarkdown+Walker.swift
//  MacDownKit
//
//  The repaired HTML tree as blocks of inline runs. Inline content keeps its
//  styling per run of text, not as a tree, because apps like Google Docs
//  write every run as a flat styled span; the renderer groups the runs back
//  into nested markers.
//

import Foundation

extension HTMLToMarkdown {
    /// A piece of inline content.
    enum Inline: Equatable {
        case text(String, TextStyle)
        /// `<br>`: a hard line break.
        case lineBreak
    }

    enum Block: Equatable {
        case paragraph([Inline])
        case heading(Int, [Inline])
    }

    struct Walker {
        var styleSheet = StyleSheet(css: "")

        /// Elements that start a block of their own; anything else is inline.
        static let blockElements: Set<String> = [
            "address", "blockquote", "body", "center", "dd", "div", "dl", "dt", "fieldset",
            "form", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "html", "li", "ol", "p", "pre",
            "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
        ]

        /// The blocks in a container. This is the one place siblings are
        /// grouped: consecutive inline nodes make an implicit paragraph.
        func blocks(in container: XMLElement, style: TextStyle = .init()) -> [Block] {
            var blocks: [Block] = []
            var pending: [Inline] = []
            func flush() {
                blocks += Self.paragraphs(pending)
                pending = []
            }
            for child in container.children ?? [] {
                if let element = child as? XMLElement,
                   Self.blockElements.contains(element.localName ?? "") {
                    flush()
                    blocks += block(element, style: self.style(of: element, inheriting: style))
                } else {
                    pending += inlines(in: child, style: style)
                }
            }
            flush()
            return blocks
        }

        /// A block element's blocks.
        func block(_ element: XMLElement, style: TextStyle) -> [Block] {
            let tag = element.localName?.lowercased() ?? ""
            if tag.count == 2, tag.first == "h", let level = Int(String(tag.last!)), (1...6).contains(level) {
                // A heading's weight isn't emphasis, and it's one line.
                let content = (element.children ?? []).flatMap { inlines(in: $0, style: style) }
                    .map { inline -> Inline in
                        guard case .text(let text, var style) = inline else { return .text(" ", .init()) }
                        style.bold = false
                        return .text(text, style)
                    }
                var inlines = Self.collapseWhitespace(content)
                Self.trimWhitespace(&inlines)
                return inlines.isEmpty ? [] : [.heading(level, inlines)]
            }
            return blocks(in: element, style: style)
        }

        /// The inline content of a node. Block elements met here (inside a
        /// heading) are set off by spaces.
        func inlines(in node: XMLNode, style: TextStyle) -> [Inline] {
            switch node.kind {
            case .text:
                return [.text(node.stringValue ?? "", style)]
            case .element:
                guard let element = node as? XMLElement else { return [] }
                let tag = element.localName?.lowercased() ?? ""
                if tag == "br" { return [.lineBreak] }
                let style = self.style(of: element, inheriting: style)
                let content = (element.children ?? []).flatMap { inlines(in: $0, style: style) }
                return Self.blockElements.contains(tag)
                    ? [.text(" ", style)] + content + [.text(" ", style)] : content
            default:
                return []
            }
        }

        func style(of element: XMLElement, inheriting parent: TextStyle) -> TextStyle {
            HTMLToMarkdown.style(of: element, inheriting: parent, styleSheet: styleSheet)
        }

        /// Paragraphs of the runs: none if they have no visible text, and a
        /// new one after each run of two or more line breaks.
        static func paragraphs(_ inlines: [Inline]) -> [Block] {
            var paragraphs: [[Inline]] = [[]]
            var breaks = 0
            for inline in collapseWhitespace(inlines) {
                switch inline {
                case .lineBreak:
                    breaks += 1
                case .text(let text, _) where text.allSatisfy(\.isWhitespace):
                    if breaks == 0 { paragraphs[paragraphs.count - 1].append(inline) }
                default:
                    if breaks >= 2 {
                        paragraphs.append([])
                    } else if breaks == 1 {
                        paragraphs[paragraphs.count - 1].append(.lineBreak)
                    }
                    breaks = 0
                    paragraphs[paragraphs.count - 1].append(inline)
                }
            }
            return paragraphs.compactMap { inlines in
                var inlines = inlines
                trimWhitespace(&inlines)
                return inlines.isEmpty ? nil : .paragraph(inlines)
            }
        }

        /// Whitespace as a browser shows it outside `pre`: each run of spaces,
        /// tabs and newlines is one space, also across runs. Non-breaking
        /// spaces become spaces, except in code.
        static func collapseWhitespace(_ inlines: [Inline]) -> [Inline] {
            var result: [Inline] = []
            var endsWithSpace = true
            for inline in inlines {
                guard case .text(let text, let style) = inline else {
                    // No space at the end of a line or the start of the next.
                    if case .text(let text, let style)? = result.last, text.hasSuffix(" ") {
                        let trimmed = String(text.dropLast())
                        if trimmed.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(trimmed, style) }
                    }
                    result.append(inline)
                    endsWithSpace = true
                    continue
                }
                var collapsed = ""
                for character in text {
                    if character == " " || character == "\t" || character.isNewline {
                        if !endsWithSpace { collapsed.append(" ") }
                        endsWithSpace = true
                    } else {
                        collapsed.append(character == "\u{a0}" && !style.monospace ? " " : character)
                        endsWithSpace = false
                    }
                }
                if !collapsed.isEmpty { result.append(.text(collapsed, style)) }
            }
            return result
        }

        /// Removes whitespace and line breaks at the start and end of a run
        /// of inlines.
        static func trimWhitespace(_ inlines: inout [Inline]) {
            while let first = inlines.first {
                if case .text(let text, let style) = first {
                    let trimmed = String(text.drop(while: \.isWhitespace))
                    if !trimmed.isEmpty { inlines[0] = .text(trimmed, style); break }
                } else if first != .lineBreak {
                    break
                }
                inlines.removeFirst()
            }
            while let last = inlines.last {
                if case .text(let text, let style) = last {
                    let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
                    if !trimmed.isEmpty { inlines[inlines.count - 1] = .text(trimmed, style); break }
                } else if last != .lineBreak {
                    break
                }
                inlines.removeLast()
            }
        }
    }
}

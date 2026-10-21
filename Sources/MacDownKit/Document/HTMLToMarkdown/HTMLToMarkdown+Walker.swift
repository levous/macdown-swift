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
        case text(String)
    }

    enum Block: Equatable {
        case paragraph([Inline])
    }

    struct Walker {
        /// Elements that start a block of their own; anything else is inline.
        static let blockElements: Set<String> = [
            "address", "blockquote", "body", "center", "dd", "div", "dl", "dt", "fieldset",
            "form", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "html", "li", "ol", "p", "pre",
            "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
        ]

        /// The blocks in a container. This is the one place siblings are
        /// grouped: consecutive inline nodes make an implicit paragraph.
        func blocks(in container: XMLElement) -> [Block] {
            var blocks: [Block] = []
            var pending: [Inline] = []
            func flush() {
                if let paragraph = Self.paragraph(pending) { blocks.append(paragraph) }
                pending = []
            }
            for child in container.children ?? [] {
                if let element = child as? XMLElement,
                   Self.blockElements.contains(element.localName ?? "") {
                    flush()
                    blocks += self.blocks(in: element)
                } else {
                    pending += inlines(in: child)
                }
            }
            flush()
            return blocks
        }

        /// The inline content of a node.
        func inlines(in node: XMLNode) -> [Inline] {
            switch node.kind {
            case .text:
                return [.text(node.stringValue ?? "")]
            case .element:
                return (node.children ?? []).flatMap(inlines(in:))
            default:
                return []
            }
        }

        /// A paragraph of the runs, or nil if they have no visible text.
        static func paragraph(_ inlines: [Inline]) -> Block? {
            var inlines = inlines
            trimWhitespace(&inlines)
            return inlines.isEmpty ? nil : .paragraph(inlines)
        }

        /// Removes whitespace at the start and end of a run of inlines.
        static func trimWhitespace(_ inlines: inout [Inline]) {
            while case .text(let text)? = inlines.first {
                let trimmed = String(text.drop(while: \.isWhitespace))
                if trimmed.isEmpty { inlines.removeFirst() } else { inlines[0] = .text(trimmed); break }
            }
            while case .text(let text)? = inlines.last {
                let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
                if trimmed.isEmpty { inlines.removeLast() } else { inlines[inlines.count - 1] = .text(trimmed); break }
            }
        }
    }
}

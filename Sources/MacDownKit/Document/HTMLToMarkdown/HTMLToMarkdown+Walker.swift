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
        case image(Image, TextStyle)
    }

    struct Image: Equatable {
        var source: String
        var alt: String
        var title: String?
    }

    enum Block: Equatable {
        case paragraph([Inline])
        case heading(Int, [Inline])
        /// A code block's language, if named, and its text.
        case code(String?, String)
        case list(List)
        case quote([Block])
        case rule
        case table(Table)

        var isList: Bool {
            if case .list = self { true } else { false }
        }
    }

    struct List: Equatable {
        var ordered: Bool
        /// The first item's number.
        var start = 1
        var items: [ListItem]
    }

    struct ListItem: Equatable {
        var blocks: [Block]
        /// A task item's checked state; nil for other items.
        var task: Bool?
        /// The item's text is in paragraphs spaced apart, as in a loose
        /// list (unlike Google Docs', whose paragraphs have no margins).
        var spaced = false
    }

    struct Walker {
        var styleSheet = StyleSheet(css: "")
        /// What relative URLs resolve against.
        var baseURL: URL?

        /// Elements that start a block of their own; anything else is inline.
        static let blockElements: Set<String> = [
            "address", "blockquote", "body", "center", "dd", "div", "dl", "dt", "fieldset",
            "form", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "html", "li", "ol", "p", "pre",
            "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
        ]

        /// Elements that aren't content, dropped with everything in them.
        static let droppedElements: Set<String> = [
            "audio", "button", "canvas", "embed", "head", "iframe", "link", "meta", "noscript",
            "object", "script", "select", "style", "svg", "template", "title", "video",
        ]

        /// An element's style, or nil if it and its content are left out:
        /// not content, or not shown.
        func visibleStyle(of element: XMLElement, inheriting parent: TextStyle) -> TextStyle? {
            let tag = element.localName?.lowercased() ?? ""
            if Self.droppedElements.contains(tag) { return nil }
            // A footnote's link back to its reference (↩), as MacDown's
            // preview writes it, means nothing without the footnote.
            if tag == "a", element.attribute(forName: "rev")?.stringValue == "footnote" { return nil }
            // Material icons are ligatures: their text is the icon's name.
            if let classes = element.attribute(forName: "class")?.stringValue,
               classes.split(separator: " ").contains(where: {
                   $0 == "material-icons" || $0.hasPrefix("material-icons-") || $0.hasPrefix("material-symbols")
               }) {
                return nil
            }
            return HTMLToMarkdown.resolvedStyle(of: element, inheriting: parent, styleSheet: styleSheet)
        }

        /// The blocks in a container. This is the one place siblings are
        /// grouped: consecutive inline nodes make an implicit paragraph.
        func blocks(in container: XMLElement, style: TextStyle = .init()) -> [Block] {
            var blocks: [Block] = []
            var pending: [Inline] = []
            // Word's list paragraphs, until something else ends the list.
            var wordItems: [WordListItem] = []
            func flush() {
                blocks += Self.paragraphs(pending)
                pending = []
            }
            func flushWordList() {
                blocks += Self.wordLists(wordItems[...])
                wordItems = []
            }
            for child in container.children ?? [] {
                guard let element = child as? XMLElement else {
                    let inlines = inlines(in: child, style: style)
                    if !wordItems.isEmpty, !Self.paragraphs(inlines).isEmpty { flushWordList() }
                    pending += inlines
                    continue
                }
                guard let elementStyle = visibleStyle(of: element, inheriting: style) else { continue }
                if Self.blockElements.contains(element.localName?.lowercased() ?? "") {
                    flush()
                    if let item = wordListItem(element, style: elementStyle) {
                        wordItems.append(item)
                        continue
                    }
                    flushWordList()
                    blocks += block(element, style: elementStyle)
                } else {
                    flushWordList()
                    pending += inlines(of: element, style: elementStyle)
                }
            }
            flush()
            flushWordList()
            return blocks
        }

        /// A block element's blocks.
        func block(_ element: XMLElement, style: TextStyle) -> [Block] {
            let tag = element.localName?.lowercased() ?? ""
            if tag.count == 2, tag.first == "h", let level = Int(String(tag.last!)), (1...6).contains(level) {
                // A heading's weight isn't emphasis, and it's one line.
                let content = (element.children ?? []).flatMap { inlines(in: $0, style: style) }
                    .map { inline -> Inline in
                        switch inline {
                        case .text(let text, var style):
                            style.bold = false
                            return .text(text, style)
                        case .lineBreak:
                            return .text(" ", .init())
                        case .image:
                            return inline
                        }
                    }
                var inlines = Self.collapseWhitespace(content)
                Self.trimWhitespace(&inlines)
                return inlines.isEmpty ? [] : [.heading(level, inlines)]
            }
            if tag == "pre" {
                return Self.codeBlock(element).map { [$0] } ?? []
            }
            if tag == "ul" || tag == "ol" {
                return list(element, style: style)
            }
            if tag == "blockquote" {
                let content = blocks(in: element, style: style)
                return content.isEmpty ? [] : [.quote(content)]
            }
            if tag == "hr" {
                return [.rule]
            }
            if tag == "table" {
                return table(element, style: style)
            }
            return blocks(in: element, style: style)
        }

        /// A `ul` or `ol` as a list. Empty items are dropped, and an
        /// item holding only lists (Tidy's repair of a list directly inside
        /// a list, as Google Docs writes it) joins the previous item.
        func list(_ element: XMLElement, style: TextStyle) -> [Block] {
            var items: [ListItem] = []
            for child in element.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                let childStyle = self.style(of: child, inheriting: style)
                let blocks = child.localName?.lowercased() == "li"
                    ? self.blocks(in: child, style: childStyle) : block(child, style: childStyle)
                guard !blocks.isEmpty else { continue }
                if !items.isEmpty, blocks.allSatisfy(\.isList) {
                    items[items.count - 1].blocks += blocks
                } else {
                    items.append(ListItem(blocks: blocks, task: Self.taskState(child),
                                          spaced: hasSpacedParagraph(child)))
                }
            }
            guard !items.isEmpty else { return [] }
            let ordered = element.localName?.lowercased() == "ol"
            let start = ordered ? element.attribute(forName: "start")?.stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1 : 1
            return [.list(List(ordered: ordered, start: max(0, start), items: items))]
        }

        /// Whether an element has a `p` child with vertical margins.
        func hasSpacedParagraph(_ element: XMLElement) -> Bool {
            (element.children ?? []).contains { node in
                guard let p = node as? XMLElement, p.localName?.lowercased() == "p" else { return false }
                let classes = p.attribute(forName: "class")?.stringValue?
                    .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
                var declarations = styleSheet.declarations(for: "p", classes: classes)
                if let inline = p.attribute(forName: "style")?.stringValue {
                    declarations.merge(HTMLToMarkdown.StyleSheet.declarations(inline)) { $1 }
                }
                func isZero(_ value: String?) -> Bool {
                    guard let value else { return false }
                    return Double(value.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))) == 0
                }
                let margin = declarations["margin"]?.split(separator: " ").map(String.init) ?? []
                let top = declarations["margin-top"] ?? margin.first
                let bottom = declarations["margin-bottom"] ?? (margin.count > 2 ? margin[2] : margin.first)
                return !(isZero(top) && isZero(bottom))
            }
        }

        /// Whether a list item is a checked or open task: a checkbox before
        /// any of its text. Nil if it isn't a task.
        static func taskState(_ item: XMLElement) -> Bool? {
            var state: Bool?
            func visit(_ node: XMLNode) -> Bool {
                if node.kind == .text {
                    return node.stringValue?.allSatisfy(\.isWhitespace) != false
                }
                guard let element = node as? XMLElement else { return true }
                if element.localName?.lowercased() == "input" {
                    if element.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" {
                        state = element.attribute(forName: "checked") != nil
                    }
                    return false
                }
                for child in element.children ?? [] where !visit(child) { return false }
                return true
            }
            _ = visit(item)
            return state
        }

        /// An image's address: its `src`, or for lazily loaded images, the
        /// first in its `srcset` or its `data-src`.
        static func imageSource(_ image: XMLElement) -> String? {
            if let source = image.attribute(forName: "src")?.stringValue, !source.isEmpty { return source }
            if let set = image.attribute(forName: "srcset")?.stringValue,
               let first = set.split(separator: ",").first?.split(whereSeparator: \.isWhitespace).first {
                return String(first)
            }
            return image.attribute(forName: "data-src")?.stringValue
        }

        /// A `pre` element's text, verbatim, as a code block.
        static func codeBlock(_ pre: XMLElement) -> Block? {
            var text = ""
            func visit(_ node: XMLNode) {
                switch node.kind {
                case .text:
                    text += node.stringValue ?? ""
                case .element:
                    guard let element = node as? XMLElement else { return }
                    let tag = element.localName?.lowercased() ?? ""
                    if tag == "br" {
                        text += "\n"
                        return
                    }
                    let isBlock = blockElements.contains(tag)
                    if isBlock, !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                    element.children?.forEach(visit)
                    if isBlock, !text.hasSuffix("\n") { text += "\n" }
                default:
                    break
                }
            }
            pre.children?.forEach(visit)
            // HTML drops a newline right after <pre>.
            if text.hasPrefix("\n") { text.removeFirst() }
            while text.last?.isNewline == true { text.removeLast() }
            guard text.contains(where: { !$0.isWhitespace }) else { return nil }
            return .code(language(of: pre), text)
        }

        /// The language named by a `language-x` or `lang-x` class on the
        /// `pre` or the `code` inside it.
        static func language(of pre: XMLElement) -> String? {
            let code = pre.elements(forName: "code").first
            for element in [pre, code].compactMap(\.self) {
                let classes = element.attribute(forName: "class")?.stringValue?.split(whereSeparator: \.isWhitespace) ?? []
                for name in classes {
                    for prefix in ["language-", "lang-"] where name.hasPrefix(prefix) && name.count > prefix.count {
                        // MacDown's preview marks code without a language
                        // `language-none`, for Prism.
                        let language = String(name.dropFirst(prefix.count))
                        return language == "none" ? nil : language
                    }
                }
            }
            return nil
        }

        /// The inline content of a node. Block elements met here (inside a
        /// heading) are set off by spaces.
        func inlines(in node: XMLNode, style: TextStyle) -> [Inline] {
            switch node.kind {
            case .text:
                return [.text(node.stringValue ?? "", style)]
            case .element:
                guard let element = node as? XMLElement,
                      let elementStyle = visibleStyle(of: element, inheriting: style)
                else { return [] }
                return inlines(of: element, style: elementStyle)
            default:
                return []
            }
        }

        /// An element's inline content, given its resolved style.
        func inlines(of element: XMLElement, style: TextStyle) -> [Inline] {
            var style = style
            let tag = element.localName?.lowercased() ?? ""
            if tag == "br" { return [.lineBreak] }
            if tag == "img" {
                // Kept as an address, never fetched.
                guard let source = Self.imageSource(element),
                      let link = link(source, title: element.attribute(forName: "title")?.stringValue)
                else { return [] }
                let alt = element.attribute(forName: "alt")?.stringValue ?? ""
                return [.image(Image(source: link.url, alt: alt, title: link.title), style)]
            }
            if tag == "a", let href = element.attribute(forName: "href")?.stringValue {
                style.link = link(href, title: element.attribute(forName: "title")?.stringValue)
            }
            let content = (element.children ?? []).flatMap { inlines(in: $0, style: style) }
            return Self.blockElements.contains(tag)
                ? [.text(" ", style)] + content + [.text(" ", style)] : content
        }

        /// A link to `href`, resolved against the base URL; nil for scripts
        /// and links within the copied page, which keep only their text.
        func link(_ href: String, title: String?) -> Link? {
            let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:")
            else { return nil }
            var url = href
            if let baseURL, let resolved = URL(string: href.replacingOccurrences(of: " ", with: "%20"),
                                               relativeTo: baseURL) {
                // WebKit writes in-page links as the page's address and a fragment.
                if resolved.fragment != nil, Self.withoutFragment(resolved) == Self.withoutFragment(baseURL) {
                    return nil
                }
                url = resolved.absoluteString
            }
            // The preview's own scheme for local files means nothing outside it.
            if let parsed = URL(string: url), parsed.scheme == PreviewURL.scheme {
                url = PreviewURL.fileURL(for: parsed).absoluteString
            }
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Link(url: url, title: title?.isEmpty == false ? title : nil)
        }

        private static func withoutFragment(_ url: URL) -> String {
            let string = url.absoluteString
            return string.firstIndex(of: "#").map { String(string[..<$0]) } ?? string
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
                    guard inline == .lineBreak else {
                        result.append(inline)
                        endsWithSpace = false
                        continue
                    }
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
                    // Icon fonts' glyphs, in the Private Use Areas, aren't
                    // text (code keeps them: terminals use them).
                    if !style.monospace, character.unicodeScalars.contains(where: Self.isPrivateUse) { continue }
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

        static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
            (0xE000...0xF8FF).contains(scalar.value) || scalar.value >= 0xF0000
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

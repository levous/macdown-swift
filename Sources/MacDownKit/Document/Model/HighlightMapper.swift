//
//  HighlightMapper.swift
//  MacDownKit
//
//  Editor highlighting from the cmark-gfm tree (FR-21, FR-22): the spans
//  PEG Markdown Highlight produced, keyed by the same element types, so the
//  bundled themes apply unchanged. Spans follow PEG's extents: headers cover
//  their line(s) and line break, emphasis, code, links and images include
//  their markup, fenced code is CODE and indented code VERBATIM, and a block
//  quote colors only its `>` markers. Footnotes are NOTE (FR-27).
//
//  What the tree doesn't keep comes from the source: reference definitions
//  (cmark consumes them) and entities (cmark decodes them). The same walk
//  collects the model's blocks.
//

import Foundation

struct HighlightMapper {
    private let text: String
    private let source: [UInt16]
    private let lineIndex: LineIndex
    private(set) var spans: [[HighlightSpan]]
    private(set) var blocks: [MarkdownDocumentModel.Block] = []

    // Collected while walking, for the source scans.
    /// Lines covered by a leaf block.
    private var leafLines = IndexSet()
    /// Paragraphs: first and last line, and the first line's column.
    private var paragraphs: [(first: Int, last: Int, column: Int)] = []
    /// Where entities may appear: paragraphs, headers and table cells.
    private var inlineContainers: [NSRange] = []
    /// Where they can't: code spans, inline HTML, autolinks, math.
    private var opaque: [NSRange]

    private let options: MarkdownDocumentModel.Options

    init(source: String, lineIndex: LineIndex, math: [NSRange],
         options: MarkdownDocumentModel.Options) {
        text = source
        self.source = Array(source.utf16)
        self.lineIndex = lineIndex
        self.options = options
        opaque = math
        spans = Array(repeating: [], count: ThemeStyle.elementNames.count)
        for range in math { add("MATH", range) }
    }

    /// The spans (sorted by position within each type) and blocks of a tree.
    static func map(_ tree: CMarkTree, source: String, lineIndex: LineIndex,
                    math: [NSRange] = [], options: MarkdownDocumentModel.Options)
        -> (highlights: HighlightElements, blocks: [MarkdownDocumentModel.Block]) {
        var mapper = HighlightMapper(source: source, lineIndex: lineIndex, math: math,
                                     options: options)
        tree.withRoot { mapper.walk($0) }
        mapper.scanReferences()
        mapper.scanEntities()
        if options.highlight { mapper.scan(ExtendedSyntax.highlight, as: "HIGHLIGHT", needing: "==") }
        if options.superscript { mapper.scan(ExtendedSyntax.superscript, as: "SUPERSCRIPT", needing: "^") }
        return (HighlightElements(spans: mapper.spans.map { $0.sorted { $0.pos < $1.pos } }),
                mapper.blocks)
    }

    // MARK: - Helpers

    private mutating func add(_ name: String, _ range: NSRange?, address: String? = nil) {
        guard let range, range.length > 0,
              let type = ThemeStyle.elementNames.firstIndex(of: name) else { return }
        spans[type].append(HighlightSpan(pos: range.location, end: NSMaxRange(range),
                                         address: address))
    }

    private func nsRange(_ node: CMarkNode) -> NSRange? {
        guard let range = node.range else { return nil }
        return lineIndex.range(from: (range.start.line, range.start.column),
                               to: (range.end.line, range.end.column))
    }

    /// The UTF-16 offset where a 1-based line starts (the text's end past
    /// the last line).
    private func lineStart(_ line: Int) -> Int {
        lineIndex.utf16Offset(line: line, column: 1) ?? source.count
    }

    /// `end` moved back past trailing line breaks, then forward over one
    /// line break, or to the next one if `end` is mid-line. Block ranges can
    /// end at the start of the following (blank) line.
    private func throughLineBreak(_ end: Int) -> Int {
        var end = end
        while end > 0, source[end - 1] == 0x0A || source[end - 1] == 0x0D { end -= 1 }
        while end < source.count, source[end] != 0x0A, source[end] != 0x0D { end += 1 }
        if end < source.count, source[end] == 0x0D { end += 1 }
        if end < source.count, source[end] == 0x0A { end += 1 }
        return end
    }

    private mutating func leaf(_ node: CMarkNode) {
        if let range = node.range {
            leafLines.insert(integersIn: range.start.line...max(range.start.line, range.end.line))
        }
    }

    private mutating func block(_ kind: MarkdownDocumentModel.Block.Kind, _ node: CMarkNode) {
        guard let range = node.range, let nsRange = nsRange(node) else { return }
        blocks.append(.init(kind: kind, lines: range.start.line...max(range.start.line, range.end.line),
                            range: nsRange))
    }

    private func character(at offset: Int) -> Character? {
        offset < source.count ? Character(Unicode.Scalar(source[offset]) ?? " ") : nil
    }

    private func plainText(_ node: CMarkNode) -> String {
        (node.kind == .text || node.kind == .code ? node.literal ?? "" : "")
            + node.children.map(plainText).joined()
    }

    // MARK: - Walk

    private mutating func walkChildren(_ node: CMarkNode) {
        var child = node.firstChild
        while let current = child {
            walk(current)
            child = current.next
        }
    }

    private mutating func walk(_ node: CMarkNode) {
        switch node.kind {
        case .paragraph:
            block(.paragraph, node)
            leaf(node)
            if let range = node.range {
                paragraphs.append((range.start.line, range.end.line, range.start.column))
            }
            if let range = nsRange(node) { inlineContainers.append(range) }
            walkChildren(node)

        case .table:
            block(.table, node)
            leaf(node)
            if let range = nsRange(node) { inlineContainers.append(range) }
            walkChildren(node)

        case .list:
            block(.list, node)
            walkChildren(node)

        case .item, .taskItem:
            block(.listItem, node)
            listMarker(node)
            walkChildren(node)

        case .heading:
            block(.heading(level: node.headingLevel), node)
            leaf(node)
            if let range = nsRange(node) {
                inlineContainers.append(range)
                // The header's line(s) and the line break after them.
                add("H\(node.headingLevel)", NSRange(
                    location: range.location,
                    length: throughLineBreak(NSMaxRange(range)) - range.location))
            }
            walkChildren(node)

        case .codeBlock:
            block(.codeBlock, node)
            leaf(node)
            guard let range = nsRange(node), let lines = node.range else { return }
            if node.isFenced {
                // Without the line break after the closing fence.
                var end = NSMaxRange(range)
                while end > range.location, let c = character(at: end - 1), c == "\n" || c == "\r" {
                    end -= 1
                }
                add("CODE", NSRange(location: range.location, length: end - range.location))
            } else {
                // Indented: whole lines, indentation and line break included.
                let start = lineStart(lines.start.line)
                add("VERBATIM", NSRange(location: start,
                                        length: throughLineBreak(NSMaxRange(range)) - start))
            }

        case .blockQuote:
            block(.blockQuote, node)
            quoteMarkers(node)
            walkChildren(node)

        case .htmlBlock:
            block(.htmlBlock, node)
            leaf(node)
            guard let range = nsRange(node) else { return }
            var end = NSMaxRange(range)
            while end > range.location, let c = character(at: end - 1), c == "\n" || c == "\r" {
                end -= 1
            }
            let html = NSRange(location: range.location, length: end - range.location)
            add("HTMLBLOCK", html)
            addComment(in: html)

        case .thematicBreak:
            block(.thematicBreak, node)
            leaf(node)
            add("HRULE", nsRange(node))

        case .footnoteDefinition:
            // The `[^label]:` that opens it, before cmark's range (which
            // starts at the content); the content is ordinary Markdown.
            if let lines = node.range, let range = nsRange(node) {
                let lineStart = lineStart(lines.start.line)
                let prefix = (text as NSString).range(
                    of: "[^", options: .backwards,
                    range: NSRange(location: lineStart, length: range.location - lineStart))
                if prefix.location != NSNotFound {
                    let close = (text as NSString).range(
                        of: "]:", range: NSRange(location: prefix.location,
                                                 length: range.location - prefix.location))
                    if close.location != NSNotFound {
                        add("NOTE", NSRange(location: prefix.location,
                                            length: NSMaxRange(close) - prefix.location))
                    }
                }
            }
            walkChildren(node)

        case .footnoteReference:
            if let range = nsRange(node) {
                add("NOTE", range)
                opaque.append(range)
            }

        case .emphasis:
            add("EMPH", nsRange(node))
            walkChildren(node)

        case .strong:
            add("STRONG", nsRange(node))
            walkChildren(node)

        case .code:
            add("CODE", nsRange(node))
            if let range = nsRange(node) { opaque.append(range) }

        case .htmlInline:
            guard let range = nsRange(node) else { return }
            add("HTML", range)
            addComment(in: range)
            opaque.append(range)

        case .link:
            link(node)

        case .image:
            add("IMAGE", nsRange(node))

        default:
            walkChildren(node)
        }
    }

    /// The marker: a bullet, or a number and its delimiter.
    private mutating func listMarker(_ node: CMarkNode) {
        guard let range = nsRange(node) else { return }
        var offset = range.location
        while character(at: offset) == " " { offset += 1 }
        if let c = character(at: offset), "-+*".contains(c) {
            add("LIST_BULLET", NSRange(location: offset, length: 1))
        } else {
            var end = offset
            while let c = character(at: end), c.isASCII, c.isNumber { end += 1 }
            if end > offset, let c = character(at: end), c == "." || c == ")" {
                add("LIST_ENUMERATOR", NSRange(location: offset, length: end + 1 - offset))
            }
        }
    }

    /// Only the `>` markers (and the space after each), line by line; lazy
    /// continuation lines have none.
    private mutating func quoteMarkers(_ node: CMarkNode) {
        guard let range = node.range else { return }
        let column = range.start.column
        for line in range.start.line...range.end.line {
            guard var offset = lineIndex.utf16Offset(line: line, column: column) else { continue }
            var spaces = 0
            while spaces < 3, character(at: offset) == " " { offset += 1; spaces += 1 }
            guard character(at: offset) == ">" else { continue }
            let length = character(at: offset + 1) == " " ? 2 : 1
            add("BLOCKQUOTE", NSRange(location: offset, length: length))
        }
    }

    private mutating func link(_ node: CMarkNode) {
        guard let range = nsRange(node) else { walkChildren(node); return }
        let url = node.url ?? ""
        let label = plainText(node)
        // An autolink: <https://…> or <a@b.c>, or a bare URL or email with
        // the Autolink setting on. Anything else starts with "[".
        if character(at: range.location) != "[" {
            // Emails without "mailto:", as PEG gave them; the editor adds it.
            let isEmail = url.hasPrefix("mailto:") && !label.hasPrefix("mailto:")
            add(isEmail ? "AUTO_LINK_EMAIL" : "AUTO_LINK_URL", range,
                address: isEmail ? label : url)
            opaque.append(range)
        } else {
            add("LINK", range, address: url)
            walkChildren(node)
        }
    }

    /// `<!-- … -->` at the start of a block or inline HTML.
    private mutating func addComment(in range: NSRange) {
        let html = (text as NSString).substring(with: range)
        guard html.hasPrefix("<!--") else { return }
        let end = (html as NSString).range(of: "-->", range: NSRange(location: 4, length: (html as NSString).length - 4))
        let length = end.location == NSNotFound ? range.length : NSMaxRange(end)
        add("COMMENT", NSRange(location: range.location, length: length))
    }

    // MARK: - Source scans

    private static let definition = try! NSRegularExpression(
        pattern: #"^\[(?!\^)(?:[^\]\\]|\\.)+\]:[ \t]*(?:<[^>\n]*>|\S+)(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?[ \t]*$"#)
    private static let containerPrefix = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>)*[ \t]*(?:(?:[-+*]|\d{1,9}[.)])[ \t]+)?"#)

    /// A reference definition on `line`, starting at UTF-16 `offset` (or
    /// after any container prefix), as REFERENCE without the line break.
    private mutating func definition(onLine line: Int, from offset: Int?) -> Bool {
        guard let lineStart = lineIndex.utf16Offset(line: line, column: 1) else { return false }
        var lineEnd = lineStart
        while lineEnd < source.count, source[lineEnd] != 0x0A, source[lineEnd] != 0x0D { lineEnd += 1 }
        let ns = text as NSString
        var start = offset ?? lineStart
        if offset == nil, let prefix = Self.containerPrefix.firstMatch(
            in: text, range: NSRange(location: lineStart, length: lineEnd - lineStart)) {
            start = NSMaxRange(prefix.range)
        }
        while start < lineEnd, source[start] == 0x20 { start += 1 }
        let range = NSRange(location: start, length: max(0, lineEnd - start))
        guard Self.definition.firstMatch(in: ns as String, options: .anchored, range: range) != nil
        else { return false }
        var end = lineEnd
        while end > start, source[end - 1] == 0x20 || source[end - 1] == 0x09 { end -= 1 }
        add("REFERENCE", NSRange(location: start, length: end - start))
        return true
    }

    /// cmark consumes reference definitions: they're lines no leaf block
    /// covers, or the first lines of a paragraph.
    private mutating func scanReferences() {
        for line in 1...lineIndex.lineCount where !leafLines.contains(line) {
            _ = definition(onLine: line, from: nil)
        }
        for paragraph in paragraphs {
            var line = paragraph.first
            var offset = lineIndex.utf16Offset(line: line, column: paragraph.column)
            while line <= paragraph.last, definition(onLine: line, from: offset) {
                line += 1
                offset = nil
            }
        }
    }

    private static let entity = try! NSRegularExpression(
        pattern: "&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);")

    /// cmark decodes entities into text, so find them in the source of
    /// paragraphs, headers and tables, outside code, HTML and math.
    private mutating func scanEntities() {
        for container in inlineContainers {
            for match in Self.entity.matches(in: text, range: container)
            where !opaque.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                add("HTML_ENTITY", match.range)
            }
        }
    }

    /// Opt-in syntax in plain text, outside code, HTML and math.
    private mutating func scan(_ pattern: NSRegularExpression, as name: String, needing marker: String) {
        let ns = text as NSString
        for container in inlineContainers
        where ns.range(of: marker, options: .literal, range: container).location != NSNotFound {
            for match in pattern.matches(in: text, range: container)
            where !opaque.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                add(name, match.range)
            }
        }
    }
}

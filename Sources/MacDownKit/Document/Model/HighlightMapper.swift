//
//  HighlightMapper.swift
//  MacDownKit
//
//  Editor highlighting from the swift-markdown tree (FR-21, FR-22): the
//  spans PEG Markdown Highlight produced, keyed by the same element types,
//  so the bundled themes apply unchanged. Spans follow PEG's extents:
//  headers cover their line(s) and line break, emphasis, code, links and
//  images include their markup, fenced code is CODE and indented code
//  VERBATIM, and a block quote colors only its `>` markers.
//
//  What the tree doesn't keep comes from the source: reference definitions
//  (cmark consumes them) and entities (cmark decodes them).
//

import Foundation
import Markdown

struct HighlightMapper: MarkupWalker {
    private let text: String
    private let source: [UInt16]
    private let lineIndex: LineIndex
    private(set) var spans: [[HighlightSpan]]

    // Collected while walking, for the source scans.
    /// Lines covered by a leaf block.
    private var leafLines = IndexSet()
    /// Paragraphs: first and last line, and the first line's column.
    private var paragraphs: [(first: Int, last: Int, column: Int)] = []
    /// Where entities may appear: paragraphs, headers and table cells.
    private var inlineContainers: [NSRange] = []
    /// Where they can't: code spans, inline HTML, autolinks, math.
    private var opaque: [NSRange]

    init(source: String, lineIndex: LineIndex, math: [NSRange]) {
        text = source
        self.source = Array(source.utf16)
        self.lineIndex = lineIndex
        opaque = math
        spans = Array(repeating: [], count: ThemeStyle.elementNames.count)
    }

    /// The spans of a parsed document, sorted by position within each type.
    static func spans(of document: Document, source: String, lineIndex: LineIndex,
                      math: [NSRange] = []) -> HighlightElements {
        var mapper = HighlightMapper(source: source, lineIndex: lineIndex, math: math)
        mapper.visit(document)
        mapper.scanReferences()
        mapper.scanEntities()
        return HighlightElements(spans: mapper.spans.map { $0.sorted { $0.pos < $1.pos } })
    }

    // MARK: - Helpers

    private mutating func add(_ name: String, _ range: NSRange?) {
        guard let range, range.length > 0,
              let type = ThemeStyle.elementNames.firstIndex(of: name) else { return }
        spans[type].append(HighlightSpan(pos: range.location, end: NSMaxRange(range), address: nil))
    }

    private func nsRange(_ markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        return lineIndex.range(from: (range.lowerBound.line, range.lowerBound.column),
                               to: (range.upperBound.line, range.upperBound.column))
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

    private mutating func leaf(_ markup: Markup) {
        if let range = markup.range {
            leafLines.insert(integersIn: range.lowerBound.line...max(range.lowerBound.line,
                                                                     range.upperBound.line))
        }
    }

    private func character(at offset: Int) -> Character? {
        offset < source.count ? Character(Unicode.Scalar(source[offset]) ?? " ") : nil
    }

    // MARK: - Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        leaf(paragraph)
        if let range = paragraph.range {
            paragraphs.append((range.lowerBound.line, range.upperBound.line, range.lowerBound.column))
        }
        if let range = nsRange(paragraph) { inlineContainers.append(range) }
        descendInto(paragraph)
    }

    mutating func visitTable(_ table: Table) {
        leaf(table)
        if let range = nsRange(table) { inlineContainers.append(range) }
        descendInto(table)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // The marker: a bullet, or a number and its delimiter.
        if let range = nsRange(listItem) {
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
        descendInto(listItem)
    }

    mutating func visitHeading(_ heading: Heading) {
        leaf(heading)
        if let range = nsRange(heading) { inlineContainers.append(range) }
        // The header's line(s) and the line break after them.
        if let range = nsRange(heading) {
            add("H\(heading.level)", NSRange(location: range.location,
                                              length: throughLineBreak(NSMaxRange(range)) - range.location))
        }
        descendInto(heading)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        leaf(codeBlock)
        guard let range = nsRange(codeBlock) else { return }
        var start = range.location
        while let c = character(at: start), c == " " { start += 1 }
        if character(at: start) == "`" || character(at: start) == "~" {
            // Fenced: without the line break after the closing fence.
            var end = NSMaxRange(range)
            while end > range.location, let c = character(at: end - 1), c == "\n" || c == "\r" {
                end -= 1
            }
            add("CODE", NSRange(location: range.location, length: end - range.location))
        } else if let lines = codeBlock.range {
            // Indented: whole lines, indentation and line break included.
            let start = lineStart(lines.lowerBound.line)
            add("VERBATIM", NSRange(location: start,
                                    length: throughLineBreak(NSMaxRange(range)) - start))
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        // Only the `>` markers (and the space after each), line by line;
        // lazy continuation lines have none.
        if let range = blockQuote.range {
            let column = range.lowerBound.column
            for line in range.lowerBound.line...range.upperBound.line {
                guard var offset = lineIndex.utf16Offset(line: line, column: column) else { continue }
                var spaces = 0
                while spaces < 3, character(at: offset) == " " { offset += 1; spaces += 1 }
                guard character(at: offset) == ">" else { continue }
                let length = character(at: offset + 1) == " " ? 2 : 1
                add("BLOCKQUOTE", NSRange(location: offset, length: length))
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        leaf(html)
        guard let range = nsRange(html) else { return }
        var end = NSMaxRange(range)
        while end > range.location, let c = character(at: end - 1), c == "\n" || c == "\r" {
            end -= 1
        }
        let block = NSRange(location: range.location, length: end - range.location)
        add("HTMLBLOCK", block)
        addComment(in: block)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        leaf(thematicBreak)
        add("HRULE", nsRange(thematicBreak))
    }

    /// `<!-- … -->` at the start of a block or inline HTML.
    private mutating func addComment(in range: NSRange) {
        let html = (text as NSString).substring(with: range)
        guard html.hasPrefix("<!--") else { return }
        let end = (html as NSString).range(of: "-->", range: NSRange(location: 4, length: (html as NSString).length - 4))
        let length = end.location == NSNotFound ? range.length : NSMaxRange(end)
        add("COMMENT", NSRange(location: range.location, length: length))
    }

    // MARK: - Inlines

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        add("EMPH", nsRange(emphasis))
        descendInto(emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        add("STRONG", nsRange(strong))
        descendInto(strong)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        add("CODE", nsRange(inlineCode))
        if let range = nsRange(inlineCode) { opaque.append(range) }
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        guard let range = nsRange(html) else { return }
        add("HTML", range)
        addComment(in: range)
        opaque.append(range)
    }

    mutating func visitLink(_ link: Link) {
        let range = nsRange(link)
        if let range, character(at: range.location) == "<" {
            // A CommonMark autolink, <https://…> or <a@b.c>.
            add(link.destination?.hasPrefix("mailto:") == true
                    && !(link.plainText.hasPrefix("mailto:")) ? "AUTO_LINK_EMAIL" : "AUTO_LINK_URL",
                range)
            opaque.append(range)
        } else {
            add("LINK", range)
            descendInto(link)
        }
    }

    mutating func visitImage(_ image: Image) {
        add("IMAGE", nsRange(image))
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
}

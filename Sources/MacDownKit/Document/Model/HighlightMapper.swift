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

import Foundation
import Markdown

struct HighlightMapper: MarkupWalker {
    private let source: [UInt16]
    private let lineIndex: LineIndex
    private(set) var spans: [[HighlightSpan]]

    init(source: String, lineIndex: LineIndex) {
        self.source = Array(source.utf16)
        self.lineIndex = lineIndex
        spans = Array(repeating: [], count: ThemeStyle.elementNames.count)
    }

    /// The spans of a parsed document, sorted by position within each type.
    static func spans(of document: Document, source: String, lineIndex: LineIndex) -> HighlightElements {
        var mapper = HighlightMapper(source: source, lineIndex: lineIndex)
        mapper.visit(document)
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

    private func character(at offset: Int) -> Character? {
        offset < source.count ? Character(Unicode.Scalar(source[offset]) ?? " ") : nil
    }

    // MARK: - Blocks

    mutating func visitHeading(_ heading: Heading) {
        // The header's line(s) and the line break after them.
        if let range = nsRange(heading) {
            add("H\(heading.level)", NSRange(location: range.location,
                                              length: throughLineBreak(NSMaxRange(range)) - range.location))
        }
        descendInto(heading)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
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
        guard let range = nsRange(html) else { return }
        var end = NSMaxRange(range)
        while end > range.location, let c = character(at: end - 1), c == "\n" || c == "\r" {
            end -= 1
        }
        add("HTMLBLOCK", NSRange(location: range.location, length: end - range.location))
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        add("HRULE", nsRange(thematicBreak))
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
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        add("HTML", nsRange(html))
    }

    mutating func visitLink(_ link: Link) {
        let range = nsRange(link)
        if let range, character(at: range.location) == "<" {
            // A CommonMark autolink, <https://…> or <a@b.c>.
            add(link.destination?.hasPrefix("mailto:") == true
                    && !(link.plainText.hasPrefix("mailto:")) ? "AUTO_LINK_EMAIL" : "AUTO_LINK_URL",
                range)
        } else {
            add("LINK", range)
            descendInto(link)
        }
    }

    mutating func visitImage(_ image: Image) {
        add("IMAGE", nsRange(image))
    }
}

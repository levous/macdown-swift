//
//  MarkdownDocumentModel.swift
//  MacDownKit
//
//  One parse of a document with swift-markdown, shared by the preview, the
//  editor highlighting and scroll sync (FR-1 to FR-3). The cmark-gfm tree
//  (Decision 10) isn't Sendable, so the model is built where the parse runs
//  (a detached task) and keeps only what's produced from the tree. Only this
//  folder uses the cmark-gfm API (TR-2).
//

import CHoedown
import Foundation

public struct MarkdownDocumentModel: Sendable {
    public struct Options: Sendable, Equatable {
        public var math = false
        public var inlineDollar = false
        public var smartPunctuation = false
        public var highlight = false
        public var superscript = false
        public var autolink = false
        /// Code block rendering: line numbers, and `lang:info` accessories.
        public var lineNumbers = false
        public var blockCodeInformation = false
        public var rendersTOC = false
        public var hardWrap = false

        public init(math: Bool = false, inlineDollar: Bool = false,
                    smartPunctuation: Bool = false, highlight: Bool = false,
                    superscript: Bool = false, autolink: Bool = false,
                    lineNumbers: Bool = false, blockCodeInformation: Bool = false) {
            self.autolink = autolink
            self.lineNumbers = lineNumbers
            self.blockCodeInformation = blockCodeInformation
            self.math = math
            self.inlineDollar = inlineDollar
            self.smartPunctuation = smartPunctuation
            self.highlight = highlight
            self.superscript = superscript
        }

        public init(_ settings: ParseSettings) {
            math = settings.extensionFlags & HOEDOWN_EXT_MATH.rawValue != 0
            inlineDollar = math && settings.extensionFlags & HOEDOWN_EXT_MATH_EXPLICIT.rawValue != 0
            smartPunctuation = settings.smartyPants
            highlight = settings.extensionFlags & HOEDOWN_EXT_HIGHLIGHT.rawValue != 0
            superscript = settings.extensionFlags & HOEDOWN_EXT_SUPERSCRIPT.rawValue != 0
            autolink = settings.extensionFlags & HOEDOWN_EXT_AUTOLINK.rawValue != 0
            lineNumbers = settings.rendererFlags & UInt32(HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS) != 0
            blockCodeInformation = settings.rendererFlags & UInt32(HOEDOWN_HTML_BLOCKCODE_INFORMATION) != 0
            rendersTOC = settings.rendersTOC
            hardWrap = settings.rendererFlags & HOEDOWN_HTML_HARD_WRAP.rawValue != 0
        }
    }

    /// A block in the document, for scroll sync and the outline.
    public struct Block: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case heading(level: Int)
            case paragraph, blockQuote, list, listItem, codeBlock, htmlBlock
            case thematicBreak, table
        }

        public let kind: Kind
        /// 1-based source lines the block spans.
        public let lines: ClosedRange<Int>
        /// UTF-16 range in the source, as the editor sees it.
        public let range: NSRange
    }

    public let source: String
    public let lineIndex: LineIndex
    public let frontMatter: ProtectedSource.FrontMatter?
    /// UTF-16 ranges of protected math, delimiters included.
    public let math: [NSRange]
    /// Blocks in document order (parents before their children).
    public let blocks: [Block]
    /// Editor highlighting, by PEG element type (`ThemeStyle.elementNames`).
    let highlights: HighlightElements
    /// The preview's HTML body, and the Prism languages its code uses.
    public let body: String
    public let languages: [String]

    public init(_ source: String, options: Options) {
        let (protected, tree) = ProtectedSource.parsed(
            source, math: options.math, inlineDollar: options.inlineDollar,
            options: .init(smartPunctuation: options.smartPunctuation, autolink: options.autolink))
        let lineIndex = LineIndex(source)
        self.source = source
        self.lineIndex = lineIndex
        frontMatter = protected.frontMatter
        math = protected.math.compactMap { range in
            guard let lower = lineIndex.utf16Offset(utf8: range.lowerBound),
                  let upper = lineIndex.utf16Offset(utf8: range.upperBound)
            else { return nil }
            return NSRange(location: lower, length: upper - lower)
        }

        (highlights, blocks) = HighlightMapper.map(tree, source: source, lineIndex: lineIndex,
                                                    math: math, options: options)
        let rendered = HTMLRenderer.render(tree, options: .init(
            lineNumbers: options.lineNumbers, blockCodeInformation: options.blockCodeInformation,
            rendersTOC: options.rendersTOC, hardWrap: options.hardWrap,
            math: Self.mathSpans(protected.math, in: source, lineIndex: lineIndex,
                                 inlineDollar: options.inlineDollar),
            highlight: options.highlight, superscript: options.superscript))
        languages = rendered.languages
        // Front matter is a table before the body (FR-15), as with hoedown.
        if let table = protected.frontMatter?.object.htmlTable {
            body = table + "\n" + rendered.html
        } else {
            body = rendered.html
        }
    }

    /// Each math span as hoedown wrote it for MathJax: `\\[…\\]` for display
    /// math, `\\(…\\)` inline, the content HTML-escaped. `$$` is display math
    /// with inline dollars on, or when it's alone in its paragraph.
    static func mathSpans(_ ranges: [Range<Int>], in source: String, lineIndex: LineIndex,
                          inlineDollar: Bool) -> [HTMLRenderer.MathSpan] {
        let bytes = Array(source.utf8)
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func isBlank(_ range: Range<Int>) -> Bool {
            bytes[range].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
        }
        func lineBounds(_ offset: Int) -> Range<Int> {
            var start = offset, end = offset
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            return start..<end
        }
        /// Nothing else in its paragraph: blank around it on its lines, and
        /// blank lines (or the document's ends) before and after.
        func isAlone(_ range: Range<Int>) -> Bool {
            let first = lineBounds(range.lowerBound), last = lineBounds(max(range.lowerBound, range.upperBound - 1))
            guard isBlank(first.lowerBound..<range.lowerBound), isBlank(range.upperBound..<last.upperBound)
            else { return false }
            let before = first.lowerBound == 0 || isBlank(lineBounds(first.lowerBound - 1))
            let after = last.upperBound >= bytes.count - 1 || isBlank(lineBounds(last.upperBound + 1))
            return before && after
        }
        return ranges.map { range in
            let span = text(range)
            let display: Bool
            let delimiter: Int
            if span.hasPrefix("$$") {
                display = inlineDollar || isAlone(range)
                delimiter = 2
            } else if span.hasPrefix("\\\\[") {
                display = true
                delimiter = 3
            } else if span.hasPrefix("\\\\(") {
                display = false
                delimiter = 3
            } else {
                display = false
                delimiter = 1
            }
            let content = text(range.lowerBound + delimiter..<range.upperBound - delimiter)
            let html = (display ? "\\[" : "\\(") + HTMLEscaping.html(content) + (display ? "\\]" : "\\)")
            let line = lineIndex.lineNumber(utf8: range.lowerBound)
            let segments = bytes[range].filter { $0 == 0x0A }.count + 1
            return .init(line: line, segments: segments, html: html)
        }
    }
}

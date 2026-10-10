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
            rendersTOC: options.rendersTOC))
        languages = rendered.languages
        // Front matter is a table before the body (FR-15), as with hoedown.
        if let table = protected.frontMatter?.object.htmlTable {
            body = table + "\n" + rendered.html
        } else {
            body = rendered.html
        }
    }
}

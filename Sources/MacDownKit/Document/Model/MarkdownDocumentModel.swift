//
//  MarkdownDocumentModel.swift
//  MacDownKit
//
//  One parse of a document with swift-markdown, shared by the preview, the
//  editor highlighting and scroll sync (FR-1 to FR-3). `Markdown.Document`
//  isn't Sendable (finding F6), so the model is built where the parse runs
//  (a detached task) and keeps only what the visitors produce from the
//  tree. Only this folder imports Markdown (TR-2).
//

import CHoedown
import Foundation
import Markdown

public struct MarkdownDocumentModel: Sendable {
    public struct Options: Sendable, Equatable {
        public var math = false
        public var inlineDollar = false
        public var smartPunctuation = false

        public init(math: Bool = false, inlineDollar: Bool = false,
                    smartPunctuation: Bool = false) {
            self.math = math
            self.inlineDollar = inlineDollar
            self.smartPunctuation = smartPunctuation
        }

        public init(_ settings: ParseSettings) {
            math = settings.extensionFlags & HOEDOWN_EXT_MATH.rawValue != 0
            inlineDollar = math && settings.extensionFlags & HOEDOWN_EXT_MATH_EXPLICIT.rawValue != 0
            smartPunctuation = settings.smartyPants
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

    public init(_ source: String, options: Options) {
        let protected = ProtectedSource(source, math: options.math,
                                        inlineDollar: options.inlineDollar)
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

        let document = Document(parsing: protected.protected,
                                options: options.smartPunctuation ? [] : .disableSmartOpts)
        var blocks: [Block] = []
        func walk(_ markup: Markup) {
            if let kind = Self.kind(of: markup), let range = markup.range,
               let nsRange = lineIndex.range(
                   from: (range.lowerBound.line, range.lowerBound.column),
                   to: (range.upperBound.line, range.upperBound.column)) {
                blocks.append(Block(kind: kind,
                                    lines: range.lowerBound.line...max(range.lowerBound.line,
                                                                       range.upperBound.line),
                                    range: nsRange))
            }
            markup.children.forEach(walk)
        }
        walk(document)
        self.blocks = blocks
        highlights = HighlightMapper.spans(of: document, source: source, lineIndex: lineIndex,
                                             math: math)
    }

    private static func kind(of markup: Markup) -> Block.Kind? {
        switch markup {
        case let heading as Heading: .heading(level: heading.level)
        case is Paragraph: .paragraph
        case is BlockQuote: .blockQuote
        case is UnorderedList, is OrderedList: .list
        case is ListItem: .listItem
        case is CodeBlock: .codeBlock
        case is HTMLBlock: .htmlBlock
        case is ThematicBreak: .thematicBreak
        case is Table: .table
        default: nil
        }
    }
}

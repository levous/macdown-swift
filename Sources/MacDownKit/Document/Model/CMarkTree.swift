//
//  CMarkTree.swift
//  MacDownKit
//
//  One cmark-gfm parse (Decision 10): the C tree, walked in place by the
//  model, the highlighter and the renderer inside the parse task. Neither
//  the tree nor its nodes are Sendable; only what's built from them leaves.
//
//  Positions are swift-markdown's convention, which the rest of the model
//  was written against: 1-based lines, 1-based UTF-8 columns, end column
//  exclusive (cmark's is inclusive), and code spans widened to include
//  their backticks (cmark's range covers only the code).
//

import cmark_gfm
import cmark_gfm_extensions

final class CMarkTree {
    struct Options: Equatable {
        var smartPunctuation = false
        var autolink = false
    }

    private let document: UnsafeMutablePointer<cmark_node>

    init(_ text: String, options: Options = .init()) {
        cmark_gfm_core_extensions_ensure_registered()
        var flags = CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES
        if options.smartPunctuation { flags |= CMARK_OPT_SMART }
        let parser = cmark_parser_new(flags)
        defer { cmark_parser_free(parser) }
        var extensions = ["table", "strikethrough", "tasklist"]
        if options.autolink { extensions.append("autolink") }
        for name in extensions {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        document = cmark_parser_finish(parser)
    }

    deinit { cmark_node_free(document) }

    /// Runs `body` with the root node. Nodes point into the tree, so they're
    /// only valid inside `body`, which keeps the tree alive (ARC could free
    /// it after the last use of `self` otherwise).
    func withRoot<T>(_ body: (CMarkNode) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try body(CMarkNode(document)) }
    }
}

struct CMarkNode {
    enum Kind: Equatable {
        case document, blockQuote, list, item, taskItem, codeBlock, htmlBlock, customBlock
        case paragraph, heading, thematicBreak, footnoteDefinition
        case table, tableHeader, tableRow, tableCell
        case text, softBreak, lineBreak, code, htmlInline, customInline
        case emphasis, strong, strikethrough, link, image, footnoteReference
        case other(String)
    }

    struct Position: Equatable {
        var line: Int
        var column: Int
    }

    let pointer: UnsafeMutablePointer<cmark_node>

    init(_ pointer: UnsafeMutablePointer<cmark_node>) { self.pointer = pointer }

    var kind: Kind {
        let type = cmark_node_get_type(pointer)
        if type == CMARK_NODE_FOOTNOTE_DEFINITION { return .footnoteDefinition }
        if type == CMARK_NODE_FOOTNOTE_REFERENCE { return .footnoteReference }
        switch String(cString: cmark_node_get_type_string(pointer)) {
        case "document": return .document
        case "block_quote": return .blockQuote
        case "list": return .list
        case "item": return .item
        case "tasklist": return .taskItem
        case "code_block": return .codeBlock
        case "html_block": return .htmlBlock
        case "custom_block": return .customBlock
        case "paragraph": return .paragraph
        case "heading": return .heading
        case "thematic_break": return .thematicBreak
        case "table": return .table
        case "table_header": return .tableHeader
        case "table_row": return .tableRow
        case "table_cell": return .tableCell
        case "text": return .text
        case "softbreak": return .softBreak
        case "linebreak": return .lineBreak
        case "code": return .code
        case "html_inline": return .htmlInline
        case "custom_inline": return .customInline
        case "emph": return .emphasis
        case "strong": return .strong
        case "strikethrough": return .strikethrough
        case "link": return .link
        case "image": return .image
        case let other: return .other(other)
        }
    }

    var children: [CMarkNode] {
        var result: [CMarkNode] = []
        var child = cmark_node_first_child(pointer)
        while let node = child {
            result.append(CMarkNode(node))
            child = cmark_node_next(node)
        }
        return result
    }

    /// The node's source range, start inclusive and end exclusive, or nil
    /// where cmark doesn't track one.
    var range: (start: Position, end: Position)? {
        let startLine = Int(cmark_node_get_start_line(pointer))
        let startColumn = Int(cmark_node_get_start_column(pointer))
        let endLine = Int(cmark_node_get_end_line(pointer))
        let endColumn = Int(cmark_node_get_end_column(pointer)) + 1
        guard startLine > 0, startColumn > 0, endLine > 0, endColumn > 0 else { return nil }
        let ticks = kind == .code ? Int(cmark_node_get_backtick_count(pointer)) : 0
        let start = Position(line: startLine, column: startColumn - ticks)
        let end = Position(line: endLine, column: endColumn + ticks)
        guard (start.line, start.column) <= (end.line, end.column) else { return nil }
        return (start, end)
    }

    var literal: String? { cmark_node_get_literal(pointer).map { String(cString: $0) } }
    var url: String? { cmark_node_get_url(pointer).map { String(cString: $0) } }
    var title: String? { cmark_node_get_title(pointer).map { String(cString: $0) } }
    var headingLevel: Int { Int(cmark_node_get_heading_level(pointer)) }
    var fenceInfo: String? { cmark_node_get_fence_info(pointer).map { String(cString: $0) } }
    var isFenced: Bool {
        // It writes the fence's length, offset and character through these.
        var length: Int32 = 0, offset: Int32 = 0
        var character: CChar = 0
        return cmark_node_get_fenced(pointer, &length, &offset, &character) != 0
    }
    var isOrderedList: Bool { cmark_node_get_list_type(pointer) == CMARK_ORDERED_LIST }
    var listStart: Int { Int(cmark_node_get_list_start(pointer)) }
    var isTight: Bool { cmark_node_get_list_tight(pointer) != 0 }
    var isChecked: Bool { cmark_gfm_extensions_get_tasklist_item_checked(pointer) }
}

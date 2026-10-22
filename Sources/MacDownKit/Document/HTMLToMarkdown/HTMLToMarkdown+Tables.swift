//
//  HTMLToMarkdown+Tables.swift
//  MacDownKit
//
//  Tables: a GFM pipe table when every cell is one line of inline
//  content and none spans rows or columns; otherwise the table stays HTML,
//  with its cells' formatting written as HTML tags.
//

import Foundation

extension HTMLToMarkdown {
    struct Table: Equatable {
        var rows: [[TableCell]]
        /// How many of the rows are in `thead`.
        var headerRows = 0

        /// Whether a pipe table can show it.
        var isPipeTable: Bool {
            rows.allSatisfy { row in
                row.allSatisfy { cell in
                    guard cell.columnSpan == 1, cell.rowSpan == 1, cell.blocks.count <= 1 else { return false }
                    if case .paragraph? = cell.blocks.first { return true }
                    return cell.blocks.isEmpty
                }
            }
        }
    }

    struct TableCell: Equatable {
        enum Alignment: Equatable { case left, center, right }

        var isHeader = false
        var columnSpan = 1
        var rowSpan = 1
        var alignment: Alignment?
        var blocks: [Block]
    }
}

extension HTMLToMarkdown.Walker {
    typealias Block = HTMLToMarkdown.Block
    typealias TextStyle = HTMLToMarkdown.TextStyle

    /// A table's caption, as a paragraph, and the table.
    func table(_ element: XMLElement, style: TextStyle) -> [Block] {
        var blocks: [Block] = []
        var rows: [XMLElement] = []
        var headerRows = 0
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            switch child.localName?.lowercased() {
            case "caption":
                blocks += self.blocks(in: child, style: self.style(of: child, inheriting: style))
            case "thead", "tbody", "tfoot":
                let section = (child.children ?? []).compactMap { $0 as? XMLElement }
                    .filter { $0.localName?.lowercased() == "tr" }
                if child.localName?.lowercased() == "thead", rows.isEmpty { headerRows = section.count }
                rows += section
            case "tr":
                rows.append(child)
            default:
                break
            }
        }
        var cells: [[HTMLToMarkdown.TableCell]] = rows.map { row in
            (row.children ?? []).compactMap { node -> HTMLToMarkdown.TableCell? in
                guard let cell = node as? XMLElement else { return nil }
                let tag = cell.localName?.lowercased()
                guard tag == "td" || tag == "th" else { return nil }
                return HTMLToMarkdown.TableCell(
                    isHeader: tag == "th",
                    columnSpan: Self.integer(cell, "colspan"),
                    rowSpan: Self.integer(cell, "rowspan"),
                    alignment: Self.alignment(cell),
                    blocks: self.blocks(in: cell, style: self.style(of: cell, inheriting: style)))
            }
        }
        // Rows without cells don't count, in the header either.
        headerRows -= cells.prefix(headerRows).filter(\.isEmpty).count
        cells.removeAll(where: \.isEmpty)
        if cells.contains(where: { $0.contains { !$0.blocks.isEmpty } }) {
            blocks.append(.table(HTMLToMarkdown.Table(rows: cells, headerRows: headerRows)))
        }
        return blocks
    }

    private static func integer(_ element: XMLElement, _ attribute: String) -> Int {
        element.attribute(forName: attribute)?.stringValue
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max(1, $0) } ?? 1
    }

    private static func alignment(_ cell: XMLElement) -> HTMLToMarkdown.TableCell.Alignment? {
        let style = cell.attribute(forName: "style")?.stringValue
            .flatMap { HTMLToMarkdown.StyleSheet.declarations($0)["text-align"] }
        switch (style ?? cell.attribute(forName: "align")?.stringValue)?.lowercased() {
        case "left", "start": return .left
        case "center": return .center
        case "right", "end": return .right
        default: return nil
        }
    }
}

extension HTMLToMarkdown.Renderer {
    typealias Block = HTMLToMarkdown.Block
    typealias Inline = HTMLToMarkdown.Inline
    typealias Table = HTMLToMarkdown.Table

    func render(_ table: Table) -> String {
        table.isPipeTable ? pipeTable(table) : htmlTable(table)
    }

    /// The first row is the header; shorter rows are padded.
    private func pipeTable(_ table: Table) -> String {
        let columns = table.rows.map(\.count).max() ?? 0
        func line(_ cells: [String]) -> String {
            "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |"
        }
        func text(_ cell: HTMLToMarkdown.TableCell) -> String {
            guard case .paragraph(let inlines)? = cell.blocks.first else { return "" }
            let oneLine = inlines.map { $0 == .lineBreak ? .text(" ", .init()) : $0 }
            // GFM splits cells before reading code spans, so `|` is escaped
            // everywhere, code included.
            return render(oneLine, atLineStart: false).replacingOccurrences(of: "|", with: "\\|")
        }
        let header = table.rows[0]
        let delimiters = (0..<columns).map { column -> String in
            switch column < header.count ? header[column].alignment : nil {
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            case nil: "---"
            }
        }
        return ([line(header.map(text)), line(delimiters)] + table.rows.dropFirst().map { line($0.map(text)) })
            .joined(separator: "\n")
    }

    /// The table as an HTML block, one row per line, its `thead` rows
    /// first.
    private func htmlTable(_ table: Table) -> String {
        let rows = table.rows.map { row in
            "<tr>" + row.map { cell in
                let tag = cell.isHeader ? "th" : "td"
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                if let alignment = cell.alignment { attributes += " align=\"\(alignment)\"" }
                return "<\(tag)\(attributes)>" + html(cell.blocks, unwrapsParagraph: true) + "</\(tag)>"
            }.joined() + "</tr>"
        }
        var lines = ["<table>"]
        if table.headerRows > 0 {
            lines += ["<thead>"] + rows.prefix(table.headerRows) + ["</thead>"]
        }
        if rows.count > table.headerRows {
            lines += ["<tbody>"] + rows.dropFirst(table.headerRows) + ["</tbody>"]
        }
        return (lines + ["</table>"]).joined(separator: "\n")
    }

    /// Blocks as HTML on one line (a blank line would end the HTML block).
    private func html(_ blocks: [Block], unwrapsParagraph: Bool = false) -> String {
        if unwrapsParagraph, blocks.count == 1, case .paragraph(let inlines) = blocks[0] {
            return html(inlines)
        }
        return blocks.map { block in
            switch block {
            case .paragraph(let inlines):
                return "<p>\(html(inlines))</p>"
            case .heading(let level, let inlines):
                return "<h\(level)>\(html(inlines))</h\(level)>"
            case .code(_, let text):
                return "<pre><code>" + HTMLEscaping.html(text).replacingOccurrences(of: "\n", with: "&#10;")
                    + "</code></pre>"
            case .list(let list):
                let tag = list.ordered ? "ol" : "ul"
                let start = list.ordered && list.start != 1 ? " start=\"\(list.start)\"" : ""
                return "<\(tag)\(start)>"
                    + list.items.map { "<li>\(html($0.blocks, unwrapsParagraph: true))</li>" }.joined()
                    + "</\(tag)>"
            case .quote(let blocks):
                return "<blockquote>\(html(blocks))</blockquote>"
            case .rule:
                return "<hr>"
            case .table(let table):
                return htmlTable(table).replacingOccurrences(of: "\n", with: "")
            }
        }.joined()
    }

    /// Inline content as HTML: each run of one style in its tags.
    private func html(_ inlines: [Inline]) -> String {
        var merged: [Inline] = []
        for inline in inlines {
            if case .text(let text, let style) = inline, case .text(let previous, style)? = merged.last {
                merged[merged.count - 1] = .text(previous + text, style)
            } else {
                merged.append(inline)
            }
        }
        return merged.map { inline in
            switch inline {
            case .lineBreak:
                return "<br>"
            case .image(let image, let style):
                var tag = "<img src=\"\(HTMLEscaping.href(image.source))\""
                if !image.alt.isEmpty { tag += " alt=\"\(HTMLEscaping.html(image.alt))\"" }
                return wrap(tag + ">", in: style)
            case .text(let text, let style):
                return wrap(HTMLEscaping.html(text), in: style)
            }
        }.joined()
    }

    private func wrap(_ content: String, in style: HTMLToMarkdown.TextStyle) -> String {
        var html = content
        if style.monospace { html = "<code>\(html)</code>" }
        if style.italic { html = "<em>\(html)</em>" }
        if style.bold { html = "<strong>\(html)</strong>" }
        if style.strike { html = "<del>\(html)</del>" }
        if let link = style.link {
            let title = link.title.map { " title=\"\(HTMLEscaping.html($0))\"" } ?? ""
            html = "<a href=\"\(HTMLEscaping.href(link.url))\"\(title)>\(html)</a>"
        }
        return html
    }
}

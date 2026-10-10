//
//  HTMLRenderer.swift
//  MacDownKit
//
//  The preview's HTML body from the cmark-gfm tree (FR-7 to FR-20, TR-4,
//  TR-5), in the markup hoedown and MacDown's patches produced, since the
//  bundled styles and page scripts rely on it: header ids `toc_N`, Prism
//  code blocks, task-list items, hoedown's footnotes. Runs inside the parse
//  task; only the HTML string leaves it.
//

import Foundation

struct HTMLRenderer {
    struct Options: Equatable {
        var lineNumbers = false
        /// `lang:info` fence strings put `info` in `data-information`.
        var blockCodeInformation = false
        /// A paragraph of just `[TOC]` becomes a table of contents.
        var rendersTOC = false
    }

    private let options: Options
    private var output = ""
    /// Where the innermost container's content starts in `output`: hoedown
    /// renders each container into its own buffer, and starts a block with
    /// a newline only when that buffer isn't empty.
    private var containerStart = 0
    private var headerCount = 0
    /// Footnote numbers by definition, in order of first reference.
    private var footnoteNumbers: [Int: Int] = [:]
    private let languages = LanguageCollector()
    /// Headers for the table of contents: level and content.
    private var headers: [(level: Int, html: String)] = []
    /// In the table of contents, links show only their text.
    private var linksAsText = false

    init(options: Options) {
        self.options = options
    }

    /// The body HTML and the Prism languages its code blocks use.
    static func render(_ tree: CMarkTree, options: Options) -> (html: String, languages: [String]) {
        var renderer = HTMLRenderer(options: options)
        tree.withRoot { renderer.renderDocument($0) }
        if options.rendersTOC { renderer.insertTableOfContents() }
        return (renderer.output, renderer.languages.languages)
    }

    // MARK: - Blocks

    private mutating func renderDocument(_ root: CMarkNode) {
        output.reserveCapacity(4096)
        var footnotes: [CMarkNode] = []
        var child = root.firstChild
        while let node = child {
            if node.kind == .footnoteDefinition { footnotes.append(node) } else { block(node) }
            child = node.next
        }
        renderFootnotes(footnotes)
    }

    private mutating func blocks(in node: CMarkNode) {
        var child = node.firstChild
        while let node = child {
            block(node)
            child = node.next
        }
    }

    /// hoedown starts each block with a newline unless it's first in its
    /// container.
    private mutating func newline() {
        if output.utf8.count > containerStart { output += "\n" }
    }

    /// Renders a container's blocks as hoedown does, in a buffer of its own.
    private mutating func contained(_ body: (inout HTMLRenderer) -> Void) {
        let saved = containerStart
        containerStart = output.utf8.count
        body(&self)
        containerStart = saved
    }

    private mutating func block(_ node: CMarkNode) {
        switch node.kind {
        case .paragraph:
            if isInTightList(node) {
                inlines(in: node)
            } else {
                newline()
                output += "<p>"
                inlines(in: node)
                output += "</p>\n"
            }

        case .heading:
            newline()
            let level = node.headingLevel
            output += "<h\(level) id=\"toc_\(headerCount)\">"
            headerCount += 1
            if options.rendersTOC {
                var toc = HTMLRenderer(options: options)
                toc.linksAsText = true
                toc.inlines(in: node)
                headers.append((level, toc.output))
            }
            inlines(in: node)
            output += "</h\(level)>\n"

        case .blockQuote:
            newline()
            output += "<blockquote>\n"
            contained { $0.blocks(in: node) }
            output += "</blockquote>\n"

        case .list:
            newline()
            if node.isOrderedList {
                output += node.listStart == 1 ? "<ol>\n" : "<ol start=\"\(node.listStart)\">\n"
            } else {
                output += "<ul>\n"
            }
            contained { $0.blocks(in: node) }
            output += node.isOrderedList ? "</ol>\n" : "</ul>\n"

        case .item:
            output += "<li>"
            contained { $0.blocks(in: node) }
            trimTrailingNewlines()
            output += "</li>\n"

        case .taskItem:
            // hoedown's patched list item: the checkbox where "[ ]" was.
            output += "<li class=\"task-list-item\">"
            let checkbox = node.isChecked ? "<input type=\"checkbox\" checked>" : "<input type=\"checkbox\">"
            if let first = node.firstChild, first.kind == .paragraph, !isInTightList(first) {
                contained { r in
                    r.output += "<p>" + checkbox + " "
                    r.inlines(in: first)
                    r.output += "</p>\n"
                    var child = first.next
                    while let next = child { r.block(next); child = next.next }
                }
            } else {
                output += checkbox + " "
                contained { $0.blocks(in: node) }
            }
            // The patched hoedown item keeps one trailing newline (its trim
            // loop is off by the checkbox's offset).
            trimTrailingNewlines()
            output += "\n</li>\n"

        case .codeBlock:
            codeBlock(node)

        case .htmlBlock:
            var html = node.literal ?? ""
            while html.hasSuffix("\n") { html.removeLast() }
            guard !html.isEmpty else { return }
            newline()
            output += html + "\n"

        case .thematicBreak:
            newline()
            output += "<hr>\n"

        case .table:
            table(node)

        default:
            blocks(in: node)
        }
    }

    private func isInTightList(_ paragraph: CMarkNode) -> Bool {
        guard let item = paragraph.parent, item.kind == .item || item.kind == .taskItem,
              let list = item.parent, list.kind == .list
        else { return false }
        return list.isTight
    }

    private mutating func trimTrailingNewlines() {
        while output.hasSuffix("\n") { output.removeLast() }
    }

    /// MacDown's Prism-compatible block code (hoedown_html_patch.c).
    private mutating func codeBlock(_ node: CMarkNode) {
        newline()
        var language = (node.fenceInfo ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        var information = ""
        if options.blockCodeInformation, let colon = language.firstIndex(of: ":") {
            information = String(language[language.index(after: colon)...])
            language = String(language[..<colon])
        }
        if !language.isEmpty {
            language = PrismLanguages.aliases[language] ?? language
            languages.add(language)
        }
        output += "<div><pre"
        if options.lineNumbers { output += " class=\"line-numbers\"" }
        if !information.isEmpty { output += " data-information=\"\(HTMLEscaping.html(information))\"" }
        output += "><code class=\"language-\(language.isEmpty ? "none" : HTMLEscaping.html(language))\">"
        var code = node.literal ?? ""
        // Without the last newline, or Prism adds a blank line.
        if code.hasSuffix("\n") { code.removeLast() }
        output += HTMLEscaping.html(code)
        output += "</code></pre></div>\n"
    }

    private mutating func table(_ node: CMarkNode) {
        newline()
        let alignments = node.tableAlignments
        output += "<table>\n"
        var row = node.firstChild
        var inBody = false
        while let current = row {
            let header = current.kind == .tableHeader
            if header {
                output += "<thead>\n"
            } else if !inBody {
                output += "\n<tbody>\n"
                inBody = true
            }
            output += "<tr>\n"
            var cell = current.firstChild
            var column = 0
            while let c = cell {
                let tag = header ? "th" : "td"
                switch column < alignments.count ? alignments[column] : "" {
                case "l": output += "<\(tag) style=\"text-align: left\">"
                case "c": output += "<\(tag) style=\"text-align: center\">"
                case "r": output += "<\(tag) style=\"text-align: right\">"
                default: output += "<\(tag)>"
                }
                inlines(in: c)
                output += "</\(tag)>\n"
                cell = c.next
                column += 1
            }
            output += "</tr>\n"
            if header { output += "</thead>\n" }
            row = current.next
        }
        // hoedown always writes a body, even an empty one.
        if !inBody { output += "\n<tbody>\n" }
        output += "</tbody>\n</table>\n"
    }

    // MARK: - Footnotes

    private mutating func footnoteNumber(_ definition: Int) -> Int {
        if let number = footnoteNumbers[definition] { return number }
        let number = footnoteNumbers.count + 1
        footnoteNumbers[definition] = number
        return number
    }

    /// hoedown's footnote list: definitions in reference order, each with a
    /// back link at the end of its first paragraph.
    private mutating func renderFootnotes(_ definitions: [CMarkNode]) {
        let numbered = definitions.compactMap { node -> (Int, CMarkNode)? in
            guard let number = footnoteNumbers[node.id] else { return nil }
            return (number, node)
        }.sorted { $0.0 < $1.0 }
        guard !numbered.isEmpty else { return }
        newline()
        output += "<div class=\"footnotes\">\n<hr>\n<ol>\n"
        for (number, node) in numbered {
            var content = HTMLRenderer(options: options)
            content.headerCount = headerCount
            content.footnoteNumbers = footnoteNumbers
            content.blocks(in: node)
            footnoteNumbers = content.footnoteNumbers
            var html = content.output
            let backLink = "&nbsp;<a href=\"#fnref\(number)\" rev=\"footnote\">&#8617;</a>"
            if let end = html.range(of: "</p>") {
                html.insert(contentsOf: backLink, at: end.lowerBound)
            }
            output += "\n<li id=\"fn\(number)\">\n" + html + "</li>\n"
        }
        output += "\n</ol>\n</div>\n"
    }

    // MARK: - Inlines

    private mutating func inlines(in node: CMarkNode) {
        var child = node.firstChild
        while let node = child {
            inline(node)
            child = node.next
        }
    }

    private mutating func inline(_ node: CMarkNode) {
        switch node.kind {
        case .text:
            output += HTMLEscaping.html(node.literal ?? "")
        case .softBreak:
            output += "\n"
        case .lineBreak:
            output += "<br>\n"
        case .code:
            output += "<code>" + HTMLEscaping.html(node.literal ?? "") + "</code>"
        case .htmlInline:
            output += node.literal ?? ""
        case .emphasis:
            output += "<em>"; inlines(in: node); output += "</em>"
        case .strong:
            output += "<strong>"; inlines(in: node); output += "</strong>"
        case .strikethrough:
            output += "<del>"; inlines(in: node); output += "</del>"
        case .link where linksAsText:
            inlines(in: node)
        case .link:
            output += "<a href=\"" + HTMLEscaping.href(node.url ?? "")
            if let title = node.title, !title.isEmpty {
                output += "\" title=\"" + HTMLEscaping.html(title)
            }
            output += "\">"
            inlines(in: node)
            output += "</a>"
        case .image:
            output += "<img src=\"" + HTMLEscaping.href(node.url ?? "") + "\" alt=\""
                + HTMLEscaping.html(plainText(node))
            if let title = node.title, !title.isEmpty {
                output += "\" title=\"" + HTMLEscaping.html(title)
            }
            output += "\">"
        case .footnoteReference:
            guard let definition = node.footnoteDefinition else { return }
            let number = footnoteNumber(definition.id)
            output += "<sup id=\"fnref\(number)\"><a href=\"#fn\(number)\" rel=\"footnote\">\(number)</a></sup>"
        default:
            inlines(in: node)
        }
    }

    private func plainText(_ node: CMarkNode) -> String {
        var text = ""
        var child = node.firstChild
        while let c = child {
            switch c.kind {
            case .text, .code: text += c.literal ?? ""
            case .softBreak, .lineBreak: text += " "
            default: text += plainText(c)
            }
            child = c.next
        }
        return text
    }

    // MARK: - Table of contents

    private static let tocParagraph = try! NSRegularExpression(
        pattern: "<p.*?>\\s*\\[TOC\\]\\s*</p>", options: .caseInsensitive)

    /// hoedown's TOC (with MacDown's "toc" class on the outer list) in place
    /// of every `[TOC]` paragraph, as MarkdownParser did.
    private mutating func insertTableOfContents() {
        guard output.contains("TOC]") else { return }
        var toc = ""
        var current = 0, offset = 0
        for (index, header) in headers.enumerated() {
            if current == 0 { offset = header.level - 1 }
            let level = header.level - offset
            if level > current {
                while level > current {
                    toc += current == 0 ? "<ul class=\"toc\">\n<li>\n" : "<ul>\n<li>\n"
                    current += 1
                }
            } else if level < current {
                toc += "</li>\n"
                while level < current {
                    toc += "</ul>\n</li>\n"
                    current -= 1
                }
                toc += "<li>\n"
            } else {
                toc += "</li>\n<li>\n"
            }
            toc += "<a href=\"#toc_\(index)\">" + header.html + "</a>\n"
        }
        while current > 0 {
            toc += "</li>\n</ul>\n"
            current -= 1
        }
        output = Self.tocParagraph.stringByReplacingMatches(
            in: output, range: NSRange(output.startIndex..., in: output),
            withTemplate: NSRegularExpression.escapedTemplate(for: toc))
    }
}

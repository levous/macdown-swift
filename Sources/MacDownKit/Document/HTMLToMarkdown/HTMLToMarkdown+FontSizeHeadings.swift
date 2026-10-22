//
//  HTMLToMarkdown+FontSizeHeadings.swift
//  MacDownKit
//
//  Headings that are only a larger font: rich text (Pages, TextEdit, through
//  AppKit's HTML) and Word for the web have no heading markup. The body size
//  is the largest size at least a quarter of the paragraph text is in (rich
//  text mixes sizes, so the most common one can be smaller than the body).
//  A paragraph is a heading when all its text is one size clearly larger
//  than that, on one short line that doesn't end like a sentence; the
//  largest heading size is `#`, the next `##`, the rest `###`. HTML with
//  real headings is left alone.
//

import Foundation

extension HTMLToMarkdown.Walker {
    /// How much larger than the body text a heading is, at least.
    static let headingSizeRatio = 1.08
    static let headingMaxLength = 80

    /// The paragraphs in `body` that are headings by their font size, and
    /// their levels.
    func fontSizeHeadings(in body: XMLElement) -> [ObjectIdentifier: Int] {
        if let headings = try? body.nodes(forXPath: ".//h1|.//h2|.//h3|.//h4|.//h5|.//h6"), !headings.isEmpty {
            return [:]
        }
        struct Paragraph {
            var element: XMLElement
            var sizes: [Double: Int]
            var unsized: Bool
        }
        var paragraphs: [Paragraph] = []
        func visit(_ element: XMLElement, size: Double?, style: HTMLToMarkdown.TextStyle) {
            let tag = element.localName?.lowercased() ?? ""
            if ["li", "ol", "pre", "table", "ul", "blockquote"].contains(tag) { return }
            guard let style = visibleStyle(of: element, inheriting: style) else { return }
            let size = fontSize(of: element, inheriting: size)
            if tag == "p" {
                var sizes: [Double: Int] = [:]
                var unsized = false
                countText(in: element, size: size, style: style, sizes: &sizes, unsized: &unsized)
                paragraphs.append(Paragraph(element: element, sizes: sizes, unsized: unsized))
                return
            }
            for case let child as XMLElement in element.children ?? [] {
                visit(child, size: size, style: style)
            }
        }
        visit(body, size: nil, style: .init())

        var totals: [Double: Int] = [:]
        for paragraph in paragraphs { totals.merge(paragraph.sizes, uniquingKeysWith: +) }
        let total = totals.values.reduce(0, +)
        guard let bodySize = totals.filter({ $0.value * 4 >= total }).keys.max() else { return [:] }

        var candidates: [(ObjectIdentifier, Double)] = []
        for paragraph in paragraphs {
            guard !paragraph.unsized, paragraph.sizes.count == 1, let size = paragraph.sizes.keys.first,
                  size >= bodySize * Self.headingSizeRatio,
                  (try? paragraph.element.nodes(forXPath: ".//br"))?.isEmpty != false
            else { continue }
            let text = (paragraph.element.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{a0}")))
            guard !text.isEmpty, text.count <= Self.headingMaxLength,
                  let last = text.last, !".:;,!?".contains(last)
            else { continue }
            candidates.append((ObjectIdentifier(paragraph.element), size))
        }
        let ranks = Set(candidates.map(\.1)).sorted(by: >)
        return Dictionary(uniqueKeysWithValues: candidates.map { id, size in
            (id, min((ranks.firstIndex(of: size) ?? 0) + 1, 3))
        })
    }

    /// The visible characters of the text in `node`, counted by font size;
    /// `unsized` notes text with no size.
    private func countText(in node: XMLNode, size: Double?, style: HTMLToMarkdown.TextStyle,
                           sizes: inout [Double: Int], unsized: inout Bool) {
        guard let element = node as? XMLElement else {
            let count = (node.stringValue ?? "").filter { !$0.isWhitespace && $0 != "\u{a0}" }.count
            guard count > 0 else { return }
            if let size { sizes[size, default: 0] += count } else { unsized = true }
            return
        }
        guard let style = visibleStyle(of: element, inheriting: style) else { return }
        let size = fontSize(of: element, inheriting: size)
        for child in element.children ?? [] {
            countText(in: child, size: size, style: style, sizes: &sizes, unsized: &unsized)
        }
    }

    /// An element's font size in pixels (to a tenth), from `font-size` or
    /// the `font` shorthand, given its parent's.
    func fontSize(of element: XMLElement, inheriting parent: Double?) -> Double? {
        let tag = element.localName?.lowercased() ?? ""
        let classes = element.attribute(forName: "class")?.stringValue?
            .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        var declarations = styleSheet.rules.isEmpty ? [:] : styleSheet.declarations(for: tag, classes: classes)
        if let inline = element.attribute(forName: "style")?.stringValue {
            declarations.merge(HTMLToMarkdown.StyleSheet.declarations(inline)) { $1 }
        }
        let value = declarations["font-size"]
            ?? declarations["font"].flatMap { font in
                font.split(separator: " ").first { $0.first?.isNumber == true }
                    .map { String($0.split(separator: "/")[0]) }
            }
        guard let value = value?.lowercased(), let size = Self.pixels(value, parent: parent) else { return parent }
        return (size * 10).rounded() / 10
    }

    private static func pixels(_ value: String, parent: Double?) -> Double? {
        for (unit, scale) in [("px", 1.0), ("pt", 4.0 / 3), ("rem", 16), ("em", parent ?? 16), ("%", (parent ?? 16) / 100)]
        where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count).trimmingCharacters(in: .whitespaces)).map { $0 * scale }
        }
        return nil
    }
}

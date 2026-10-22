//
//  HTMLToMarkdown+Word.swift
//  MacDownKit
//
//  Word's lists: Word writes each list item as a paragraph styled
//  `mso-list: lN levelM`, its bullet or number as text in a span styled
//  `mso-list: Ignore`. Word for the web writes each item as a list of its
//  own, in a wrapper `div`, with `data-listid` and `data-aria-level` on the
//  `li`. Either way, consecutive items become nested lists again.
//

import Foundation

extension HTMLToMarkdown.Walker {
    struct WordListItem {
        /// Word's list id (`l0`) and nesting level (1 is the outermost).
        var list: String
        var level: Int
        var ordered: Bool
        var start: Int
        var blocks: [HTMLToMarkdown.Block]
    }

    /// The list item a Word paragraph is, or nil if it isn't one.
    func wordListItem(_ element: XMLElement, style: HTMLToMarkdown.TextStyle) -> WordListItem? {
        guard element.localName?.lowercased() == "p",
              let attribute = element.attribute(forName: "style")?.stringValue,
              let value = HTMLToMarkdown.StyleSheet.declarations(attribute)["mso-list"]?.lowercased()
        else { return nil }
        let parts = value.split(separator: " ")
        guard let list = parts.first(where: { $0.hasPrefix("l") && !$0.hasPrefix("level") && !$0.hasPrefix("lfo") }),
              let level = parts.first(where: { $0.hasPrefix("level") }).flatMap({ Int($0.dropFirst(5)) })
        else { return nil }
        let (ordered, start) = Self.listKind(Self.wordListMarker(in: element) ?? "")
        return WordListItem(list: String(list), level: level, ordered: ordered, start: start,
                            blocks: blocks(in: element, style: style))
    }

    /// The list items a Word for the web list (or its wrapper `div`) holds,
    /// or nil if it isn't one: every item must say its list and level.
    func webWordListItems(_ element: XMLElement, style: HTMLToMarkdown.TextStyle) -> [WordListItem]? {
        let tag = element.localName?.lowercased()
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        if tag == "div" {
            guard !children.isEmpty, (element.children ?? []).allSatisfy({
                $0 is XMLElement || ($0.stringValue ?? "").allSatisfy(\.isWhitespace)
            }) else { return nil }
            var items: [WordListItem] = []
            for child in children {
                guard let style = visibleStyle(of: child, inheriting: style),
                      let childItems = webWordListItems(child, style: style) else { return nil }
                items += childItems
            }
            return items
        }
        guard tag == "ul" || tag == "ol", !children.isEmpty else { return nil }
        let ordered = tag == "ol"
        let start = element.attribute(forName: "start")?.stringValue
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
        var items: [WordListItem] = []
        for child in children {
            guard child.localName?.lowercased() == "li",
                  let list = child.attribute(forName: "data-listid")?.stringValue,
                  let level = child.attribute(forName: "data-aria-level")?.stringValue.flatMap({ Int($0) })
            else { return nil }
            items.append(WordListItem(list: list, level: level, ordered: ordered, start: max(0, start),
                                      blocks: blocks(in: child, style: self.style(of: child, inheriting: style))))
        }
        return items
    }

    /// The bullet or number Word wrote for a list paragraph.
    static func wordListMarker(in element: XMLElement) -> String? {
        for case let child as XMLElement in element.children ?? [] {
            if let attribute = child.attribute(forName: "style")?.stringValue,
               HTMLToMarkdown.StyleSheet.declarations(attribute)["mso-list"]?.lowercased() == "ignore" {
                return child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{a0}")))
            }
            if let marker = wordListMarker(in: child) { return marker }
        }
        return nil
    }

    /// Whether a list marker is a number (or letter, or Roman numeral), and
    /// the number it starts at.
    static func listKind(_ marker: String) -> (ordered: Bool, start: Int) {
        let digits = marker.prefix { $0.isASCII && $0.isNumber }
        let rest = marker.dropFirst(digits.count)
        if let number = Int(digits), rest.first == "." || rest.first == ")" {
            return (true, number)
        }
        if let last = marker.last, last == "." || last == ")",
           marker.dropLast().allSatisfy({ $0.isASCII && $0.isLetter }), marker.count > 1 {
            return (true, 1)
        }
        return (false, 1)
    }

    /// Word list items as nested lists: deeper items join the item before
    /// them, and a different list or kind at the same level starts a new
    /// list.
    static func wordLists(_ items: ArraySlice<WordListItem>) -> [HTMLToMarkdown.Block] {
        guard let base = items.map(\.level).min() else { return [] }
        var blocks: [HTMLToMarkdown.Block] = []
        var current: (list: String, ordered: Bool, value: HTMLToMarkdown.List)?
        var index = items.startIndex
        while index < items.endIndex {
            let item = items[index]
            if item.level > base {
                let end = items[index...].firstIndex { $0.level <= base } ?? items.endIndex
                let sublists = wordLists(items[index..<end])
                var list = current?.value ?? HTMLToMarkdown.List(ordered: false, items: [])
                if list.items.isEmpty {
                    list.items.append(HTMLToMarkdown.ListItem(blocks: sublists))
                } else {
                    list.items[list.items.count - 1].blocks += sublists
                }
                current = (current?.list ?? item.list, current?.ordered ?? false, list)
                index = end
                continue
            }
            if let open = current, open.list != item.list || open.ordered != item.ordered {
                blocks.append(.list(open.value))
                current = nil
            }
            var list = current?.value ?? HTMLToMarkdown.List(ordered: item.ordered, start: item.start, items: [])
            list.items.append(HTMLToMarkdown.ListItem(blocks: item.blocks))
            current = (item.list, item.ordered, list)
            index += 1
        }
        if let current { blocks.append(.list(current.value)) }
        return blocks
    }
}

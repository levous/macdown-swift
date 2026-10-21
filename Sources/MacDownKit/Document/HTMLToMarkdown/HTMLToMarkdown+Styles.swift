//
//  HTMLToMarkdown+Styles.swift
//  MacDownKit
//
//  The formatting of each element as the reader sees it: from its tag, the
//  `<style>` rules matching its classes, its `style` attribute and its
//  ancestors. Google Docs, Word and AppKit's RTF export mark bold, italic and
//  code fonts with styles rather than tags, so the walker reads these instead
//  of tag names.
//

import Foundation

extension HTMLToMarkdown {
    /// The formatting with a Markdown equivalent.
    struct TextStyle: Equatable, Hashable {
        var bold = false
        var italic = false
        var strike = false
        var monospace = false
        /// The link the text is in.
        var link: Link?
    }

    struct Link: Equatable, Hashable {
        var url: String
        var title: String?
    }

    /// The simple rules of a document's `<style>` blocks: `tag`, `.class` and
    /// `tag.class` selectors. Rules with other selectors, and `@` rules, are
    /// ignored.
    struct StyleSheet {
        struct Rule {
            var tag: String?
            var classes: [String]
            var declarations: [String: String]
            var specificity: Int { (tag == nil ? 0 : 1) + classes.count * 10 }
        }

        var rules: [Rule] = []

        init(css: String) {
            var css = css.replacingOccurrences(of: "<!--", with: " ")
                .replacingOccurrences(of: "-->", with: " ")
            while let start = css.range(of: "/*") {
                let end = css.range(of: "*/", range: start.upperBound..<css.endIndex)?.upperBound ?? css.endIndex
                css.removeSubrange(start.lowerBound..<end)
            }
            for chunk in css.split(separator: "}") {
                let parts = chunk.split(separator: "{", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let selectors = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selectors.hasPrefix("@") else { continue }
                let declarations = Self.declarations(String(parts[1]))
                for selector in selectors.split(separator: ",") {
                    let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !selector.isEmpty,
                          selector.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
                    else { continue }
                    var names = selector.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                    let tag = names.removeFirst()
                    rules.append(Rule(tag: tag.isEmpty ? nil : tag.lowercased(), classes: names,
                                      declarations: declarations))
                }
            }
        }

        /// The declarations of the rules matching an element, lowest
        /// specificity first, so later ones win.
        func declarations(for tag: String, classes: [String]) -> [String: String] {
            rules.enumerated()
                .filter { _, rule in
                    (rule.tag == nil || rule.tag == tag) && rule.classes.allSatisfy(classes.contains)
                }
                .sorted { ($0.element.specificity, $0.offset) < ($1.element.specificity, $1.offset) }
                .reduce(into: [:]) { result, rule in result.merge(rule.element.declarations) { $1 } }
        }

        /// `name: value; …` as a dictionary of lowercased names.
        static func declarations(_ text: String) -> [String: String] {
            var result: [String: String] = [:]
            for declaration in text.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "!important", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { result[name] = value }
            }
            return result
        }
    }

    /// Fonts that are monospace, besides any named "… Mono".
    static let monospaceFonts: Set<String> = [
        "andale mono", "cascadia code", "consolas", "courier", "courier new", "fira code",
        "hack", "inconsolata", "lucida console", "lucida sans typewriter", "menlo", "monaco",
        "monospace", "source code pro", "sf mono", "sfmono-regular", "ui-monospace",
    ]

    /// Whether a `font-family` list asks for a monospace font: its first
    /// family, or the generic family it falls back to.
    static func isMonospace(fontFamily: String) -> Bool {
        let families = fontFamily.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        guard let first = families.first else { return false }
        if monospaceFonts.contains(first) || first.contains("mono") { return true }
        return families.last == "monospace"
    }

    /// The `font` shorthand: optional style, variant and weight keywords, a
    /// size (with an optional `/line-height`), then the family list.
    static func fontShorthand(_ value: String) -> (bold: Bool, italic: Bool, family: String?) {
        var bold = false, italic = false
        var rest = Substring(value)
        while let token = rest.split(separator: " ", maxSplits: 1).first {
            let word = token.lowercased()
            let isSize = word.first?.isNumber == true || word.first == "."
                || ["xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
                    "smaller", "larger"].contains(word.split(separator: "/").first.map(String.init) ?? "")
            rest = rest.dropFirst(token.count).drop(while: \.isWhitespace)
            if isSize {
                return (bold, italic, rest.isEmpty ? nil : String(rest))
            }
            switch word {
            case "bold", "bolder": bold = true
            case "italic", "oblique": italic = true
            default:
                if let weight = Int(word), weight >= 600 { bold = true }
            }
        }
        return (bold, italic, nil)
    }

    static let boldTags: Set<String> = ["b", "strong"]
    static let italicTags: Set<String> = ["cite", "dfn", "em", "i", "var"]
    static let strikeTags: Set<String> = ["del", "s", "strike"]
    static let monospaceTags: Set<String> = ["code", "kbd", "pre", "samp", "tt"]

    /// An element's style, given its parent's.
    static func style(of element: XMLElement, inheriting parent: TextStyle,
                      styleSheet: StyleSheet) -> TextStyle {
        let tag = element.localName?.lowercased() ?? ""
        var style = parent
        if boldTags.contains(tag) { style.bold = true }
        if italicTags.contains(tag) { style.italic = true }
        if strikeTags.contains(tag) { style.strike = true }
        if monospaceTags.contains(tag) { style.monospace = true }

        let classes = element.attribute(forName: "class")?.stringValue?
            .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        var declarations = styleSheet.declarations(for: tag, classes: classes)
        if let inline = element.attribute(forName: "style")?.stringValue {
            declarations.merge(StyleSheet.declarations(inline)) { $1 }
        }
        if let font = declarations["font"] {
            let shorthand = fontShorthand(font)
            // The shorthand resets what it doesn't name.
            style.bold = shorthand.bold || boldTags.contains(tag)
            style.italic = shorthand.italic || italicTags.contains(tag)
            if let family = shorthand.family { style.monospace = isMonospace(fontFamily: family) }
        }
        if let weight = declarations["font-weight"]?.lowercased() {
            style.bold = weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600
        }
        if let fontStyle = declarations["font-style"]?.lowercased() {
            style.italic = fontStyle == "italic" || fontStyle.hasPrefix("oblique")
        }
        if let family = declarations["font-family"] {
            style.monospace = isMonospace(fontFamily: family)
        }
        // A decoration can't be cancelled by a descendant, only added.
        for name in ["text-decoration", "text-decoration-line"] {
            if declarations[name]?.lowercased().contains("line-through") == true { style.strike = true }
        }
        return style
    }
}

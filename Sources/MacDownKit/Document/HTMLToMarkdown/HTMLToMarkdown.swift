//
//  HTMLToMarkdown.swift
//  MacDownKit
//
//  Pasted HTML (or RTF, through AppKit's HTML export) as Markdown (paste
//  intent, "The converter"). Foundation's XMLDocument repairs the HTML into a
//  tree; the walker turns it into blocks of styled inline runs; the renderer
//  writes the Markdown, following the writer's list marker and indentation.
//  The parsed document never leaves `convert`.
//

import Foundation

public struct HTMLToMarkdown: Sendable {
    public struct Options: Sendable, Equatable {
        /// The unordered list marker (`Preferences.editorUnorderedListMarker`).
        public var listMarker: String
        /// One level of nesting: four spaces, or a tab.
        public var indent: String
        /// What relative links and images resolve against: the page the
        /// HTML was copied from.
        public var baseURL: URL?

        public init(listMarker: String = "*", indent: String = "\t", baseURL: URL? = nil) {
            self.listMarker = listMarker
            self.indent = indent
            self.baseURL = baseURL
        }
    }

    public struct Result: Sendable, Equatable {
        public var markdown: String
        /// A single paragraph, inserted inline without paragraph breaks
        /// around it (FR-9).
        public var isInline: Bool
    }

    public var options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// The Markdown for `html`, or nil if it can't be parsed or has no
    /// visible content (the caller pastes plain text instead).
    public func convert(_ html: String) -> Result? {
        let result = Renderer(options: options).render(Self.blocks(html, baseURL: options.baseURL))
        return result.markdown.isEmpty ? nil : result
    }

    /// The blocks of `html`, empty if it can't be parsed.
    static func blocks(_ html: String, baseURL: URL? = nil) -> [Block] {
        guard let (document, body) = parse(html) else { return [] }
        let css = ((try? document.nodes(forXPath: "//style")) ?? []).compactMap(\.stringValue)
        return Walker(styleSheet: StyleSheet(css: css.joined(separator: "\n")), baseURL: baseURL)
            .blocks(in: body)
    }

    // MARK: - Parsing

    /// HTML5 block elements Tidy (HTML 4) would drop, keeping their content
    /// but losing the block boundary.
    static let html5Blocks = ["article", "aside", "details", "dialog", "figcaption", "figure",
                              "footer", "header", "hgroup", "main", "nav", "section", "summary"]
    static let html5Inlines = ["mark", "time"]

    private static let html5BlockPattern = try! NSRegularExpression(
        pattern: "<(/?)(?:\(html5Blocks.joined(separator: "|")))(?=[\\s>/])", options: .caseInsensitive)
    /// HTML5 elements whose content isn't text; Tidy would drop the tags
    /// and keep the content.
    private static let nonTextPattern = try! NSRegularExpression(
        pattern: "<(template|svg)\\b.*?</\\1\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let html5InlinePattern = try! NSRegularExpression(
        pattern: "<(/?)(?:\(html5Inlines.joined(separator: "|")))(?=[\\s>/])", options: .caseInsensitive)

    /// The repaired document and its `body`. The document must outlive the
    /// body: nodes don't keep their document alive.
    static func parse(_ html: String) -> (XMLDocument, XMLElement)? {
        guard html.contains(where: { !$0.isWhitespace }) else { return nil }
        var source = nonTextPattern.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        source = html5BlockPattern.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "<$1div")
        source = html5InlinePattern.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "<$1span")
        // XMLDocument only repairs (tidies) input that isn't well-formed XML
        // and is longer than a few bytes; anything else parses as XML
        // without a body, or not at all. An unclosed meta makes sure.
        source = #"<meta charset="utf-8">"# + source
        guard let document = try? XMLDocument(xmlString: source, options: [.documentTidyHTML]),
              let body = try? document.nodes(forXPath: "//body").first as? XMLElement
        else { return nil }
        return (document, body)
    }
}

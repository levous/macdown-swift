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
        /// around it.
        public var isInline: Bool
        /// The HTML looks like code from a code editor or terminal, to be
        /// pasted as plain text instead.
        public var isCode = false
    }

    public var options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// The Markdown for `html`, or nil if it can't be parsed or has no
    /// visible content (the caller pastes plain text instead).
    public func convert(_ html: String) -> Result? {
        let blocks = Self.blocks(html, baseURL: options.baseURL)
        var result = Renderer(options: options).render(blocks)
        result.isCode = Self.isCode(blocks)
        return result.markdown.isEmpty ? nil : result
    }

    /// Whether blocks look like code copied from a code editor or terminal:
    /// all their visible text is monospace (or in code blocks), with
    /// no links, images, headings, lists, quotes or tables. Bold or colored
    /// keywords, as some editors' themes have, don't count.
    static func isCode(_ blocks: [Block]) -> Bool {
        !blocks.isEmpty && blocks.allSatisfy { block in
            switch block {
            case .code:
                return true
            case .paragraph(let inlines):
                return inlines.allSatisfy { inline in
                    switch inline {
                    case .lineBreak: true
                    case .image: false
                    case .text(let text, let style):
                        style.link == nil && (style.monospace || text.allSatisfy(\.isWhitespace))
                    }
                }
            default:
                return false
            }
        }
    }

    /// The blocks of `html`, empty if it can't be parsed.
    static func blocks(_ html: String, baseURL: URL? = nil) -> [Block] {
        guard let (document, body) = parse(html) else { return [] }
        let css = ((try? document.nodes(forXPath: "//style")) ?? []).compactMap(\.stringValue)
        var walker = Walker(styleSheet: StyleSheet(css: css.joined(separator: "\n")), baseURL: baseURL)
        // Repairs for what particular writers lose, applied only to their
        // HTML: elsewhere a larger short paragraph or two lists in a row
        // mean what they say.
        let fromAppKit = ((try? document.nodes(forXPath: "//meta")) ?? []).contains {
            ($0 as? XMLElement)?.attribute(forName: "content")?.stringValue == "Cocoa HTML Writer"
        }
        let fromWordForTheWeb = ((try? body.nodes(forXPath: ".//*[@paraid]")) ?? []).isEmpty == false
        walker.repairsAppKitLists = fromAppKit
        if fromAppKit || fromWordForTheWeb {
            walker.sizeHeadings = walker.fontSizeHeadings(in: body)
        }
        return walker.blocks(in: body)
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

//
//  MarkdownParser.swift
//  MacDown
//
//  The hoedown bridge, ported from the C-level parts of MPRenderer.m.
//  Everything here is free of actor state so it can run in the background.
//

import Foundation
import CHoedown

/// Settings that affect the Markdown → HTML body conversion.
public struct ParseSettings: Sendable, Equatable {
    public var extensionFlags: UInt32 = 0
    public var rendererFlags: UInt32 = 0
    public var smartyPants = false
    public var rendersTOC = false
    public var detectsFrontMatter = false
    /// Which parser renders: hoedown, or cmark-gfm through the document
    /// model (the hidden `markdownEngine` setting).
    public var engine = MarkdownEngine.swiftMarkdown

    public init(extensionFlags: UInt32 = 0, rendererFlags: UInt32 = 0,
                smartyPants: Bool = false, rendersTOC: Bool = false,
                detectsFrontMatter: Bool = false, engine: MarkdownEngine = .swiftMarkdown) {
        self.extensionFlags = extensionFlags
        self.rendererFlags = rendererFlags
        self.smartyPants = smartyPants
        self.rendersTOC = rendersTOC
        self.detectsFrontMatter = detectsFrontMatter
        self.engine = engine
    }
}

public struct ParseResult: Sendable, Equatable {
    /// The rendered HTML body.
    public var body: String
    /// Prism languages used in code blocks, dependencies first.
    public var languages: [String]
}

public enum MarkdownParser {
    static let nestingLevel = Int(Int32.max)
    static let tocLevel: Int32 = 6     // h1 to h6.

    public static func parse(_ markdown: String, settings: ParseSettings) -> ParseResult {
        var markdown = markdown
        var frontMatterHTML: String?
        if settings.detectsFrontMatter {
            let (object, offset) = markdown.frontMatter()
            if offset > 0 {
                markdown = markdown.ns.substring(from: offset)
            }
            frontMatterHTML = object?.htmlTable
        }

        let collector = LanguageCollector()
        let unmanaged = Unmanaged.passRetained(collector)
        defer { unmanaged.release() }

        let htmlRenderer = createHTMLRenderer(flags: settings.rendererFlags,
                                              owner: unmanaged.toOpaque())
        defer { freeHTMLRenderer(htmlRenderer) }
        var tocRenderer: UnsafeMutablePointer<hoedown_renderer>?
        if settings.rendersTOC {
            tocRenderer = hoedown_html_toc_renderer_new(tocLevel)
            tocRenderer?.pointee.header = hoedown_patch_render_toc_header
        }
        defer { if let tocRenderer { hoedown_html_renderer_free(tocRenderer) } }

        var body = render(markdown, renderer: htmlRenderer,
                          extensions: settings.extensionFlags,
                          smartyPants: settings.smartyPants)
        if let tocRenderer {
            let toc = render(markdown, renderer: tocRenderer,
                             extensions: settings.extensionFlags,
                             smartyPants: false)
            body = tocRegex.stringByReplacingMatches(
                in: body, range: NSRange(location: 0, length: body.ns.length),
                withTemplate: NSRegularExpression.escapedTemplate(for: toc))
        }
        if let frontMatterHTML {
            body = "\(frontMatterHTML)\n\(body)"
        }
        return ParseResult(body: body, languages: collector.languages)
    }

    private static let tocRegex = try! NSRegularExpression(
        pattern: "<p.*?>\\s*\\[TOC\\]\\s*</p>", options: .caseInsensitive)

    private static func render(_ text: String,
                               renderer: UnsafeMutablePointer<hoedown_renderer>,
                               extensions: UInt32, smartyPants: Bool) -> String {
        let document = hoedown_document_new(
            renderer, hoedown_extensions(rawValue: extensions), nestingLevel)
        defer { hoedown_document_free(document) }

        var ob = hoedown_buffer_new(64)
        var utf8 = Array(text.utf8)
        utf8.withUnsafeMutableBufferPointer { buffer in
            hoedown_document_render(document, ob, buffer.baseAddress, buffer.count)
        }
        if smartyPants {
            let ib = ob
            ob = hoedown_buffer_new(64)
            hoedown_html_smartypants(ob, ib?.pointee.data, ib?.pointee.size ?? 0)
            hoedown_buffer_free(ib)
        }
        defer { hoedown_buffer_free(ob) }
        guard let ob, let data = ob.pointee.data else { return "" }
        let bytes = UnsafeBufferPointer(start: data, count: ob.pointee.size)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func createHTMLRenderer(
        flags: UInt32, owner: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<hoedown_renderer> {
        let renderer = hoedown_html_renderer_new(
            hoedown_html_flags(rawValue: flags), tocLevel)!
        renderer.pointee.blockcode = hoedown_patch_render_blockcode
        renderer.pointee.listitem = hoedown_patch_render_listitem

        let extra = UnsafeMutablePointer<hoedown_html_renderer_state_extra>
            .allocate(capacity: 1)
        extra.initialize(to: hoedown_html_renderer_state_extra(
            language_addition: languageAddition, owner: owner))
        let state = renderer.pointee.opaque
            .assumingMemoryBound(to: hoedown_html_renderer_state.self)
        state.pointee.opaque = UnsafeMutableRawPointer(extra)
        return renderer
    }

    private static func freeHTMLRenderer(_ renderer: UnsafeMutablePointer<hoedown_renderer>) {
        let state = renderer.pointee.opaque
            .assumingMemoryBound(to: hoedown_html_renderer_state.self)
        if let extra = state.pointee.opaque {
            extra.assumingMemoryBound(to: hoedown_html_renderer_state_extra.self)
                .deallocate()
            state.pointee.opaque = nil
        }
        hoedown_html_renderer_free(renderer)
    }
}

/// Called by the patched block code renderer for every fenced code block
/// language. Maps aliases and records the Prism scripts required.
private let languageAddition: @convention(c) (
    UnsafePointer<hoedown_buffer>?, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<hoedown_buffer>? = { language, owner in
    guard let language, let owner, let data = language.pointee.data else {
        return nil
    }
    let collector = Unmanaged<LanguageCollector>.fromOpaque(owner)
        .takeUnretainedValue()
    var lang = String(decoding: UnsafeBufferPointer(start: data,
                                                    count: language.pointee.size),
                      as: UTF8.self)

    // Try to identify alias and point it to the "real" language name.
    var mapped: UnsafeMutablePointer<hoedown_buffer>?
    if let real = PrismLanguages.aliases[lang] {
        lang = real
        let bytes = Array(real.utf8)
        mapped = hoedown_buffer_new(64)
        hoedown_buffer_put(mapped, bytes, bytes.count)
    }
    // Walk dependencies to include all required scripts.
    collector.add(lang)
    return mapped
}

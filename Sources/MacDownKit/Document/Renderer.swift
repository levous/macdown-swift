//
//  Renderer.swift
//  MacDown
//
//  Ported from MPRenderer.m. Turns Markdown into a complete HTML page with
//  the styles and scripts selected in preferences.
//

import Foundation
import CHoedown

/// Settings that affect how the HTML page is assembled around the body.
public struct PageSettings: Sendable, Equatable {
    public var styleName: String?
    public var syntaxHighlighting = false
    public var highlightingThemeName: String?
    public var lineNumbers = false
    public var codeBlockAccessory: CodeBlockAccessoryType = .none
    public var taskList = false
    public var mermaid = false
    public var graphviz = false
    public var mathJax = false
    public var templateName = "Default"

    public init() {}
}

public struct RenderSettings: Sendable, Equatable {
    public var parse = ParseSettings()
    public var page = PageSettings()

    public init(parse: ParseSettings = ParseSettings(),
                page: PageSettings = PageSettings()) {
        self.parse = parse
        self.page = page
    }
}

@MainActor
extension Preferences {
    public var extensionFlags: UInt32 {
        var flags: UInt32 = 0
        if extensionAutolink { flags |= HOEDOWN_EXT_AUTOLINK.rawValue }
        if extensionFencedCode { flags |= HOEDOWN_EXT_FENCED_CODE.rawValue }
        if extensionFootnotes { flags |= HOEDOWN_EXT_FOOTNOTES.rawValue }
        if extensionHighlight { flags |= HOEDOWN_EXT_HIGHLIGHT.rawValue }
        if !extensionIntraEmphasis { flags |= HOEDOWN_EXT_NO_INTRA_EMPHASIS.rawValue }
        if extensionQuote { flags |= HOEDOWN_EXT_QUOTE.rawValue }
        if extensionStrikethough { flags |= HOEDOWN_EXT_STRIKETHROUGH.rawValue }
        if extensionSuperscript { flags |= HOEDOWN_EXT_SUPERSCRIPT.rawValue }
        if extensionTables { flags |= HOEDOWN_EXT_TABLES.rawValue }
        if htmlMathJax { flags |= HOEDOWN_EXT_MATH.rawValue }
        if htmlMathJaxInlineDollar { flags |= HOEDOWN_EXT_MATH_EXPLICIT.rawValue }
        return flags
    }

    public var rendererFlags: UInt32 {
        var flags: UInt32 = 0
        if htmlTaskList { flags |= UInt32(HOEDOWN_HTML_USE_TASK_LIST) }
        if htmlLineNumbers { flags |= UInt32(HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS) }
        if htmlHardWrap { flags |= HOEDOWN_HTML_HARD_WRAP.rawValue }
        if codeBlockAccessory == .custom {
            flags |= UInt32(HOEDOWN_HTML_BLOCKCODE_INFORMATION)
        }
        return flags
    }

    public var renderSettings: RenderSettings {
        var page = PageSettings()
        page.styleName = htmlStyleName
        page.syntaxHighlighting = htmlSyntaxHighlighting
        page.highlightingThemeName = htmlHighlightingThemeName
        page.lineNumbers = htmlLineNumbers
        page.codeBlockAccessory = codeBlockAccessory
        page.taskList = htmlTaskList
        page.mermaid = htmlMermaid
        page.graphviz = htmlGraphviz
        page.mathJax = htmlMathJax
        page.templateName = htmlTemplateName ?? "Default"
        return RenderSettings(
            parse: ParseSettings(extensionFlags: extensionFlags,
                                 rendererFlags: rendererFlags,
                                 smartyPants: extensionSmartyPants,
                                 rendersTOC: htmlRendersTOC,
                                 detectsFrontMatter: htmlDetectFrontMatter),
            page: page)
    }
}

/// Assembles complete HTML pages. Pure functions of their inputs.
public enum PageBuilder {
    static let mathJaxCDN = URL(string:
        "https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.3/MathJax.js"
        + "?config=TeX-AMS-MML_HTMLorMML")!
    static let prismScriptDirectory = "Prism/components"
    static let prismPluginDirectory = "Prism/plugins"

    static var bundle: Bundle { MPPaths.resourceBundle }

    static func extensionURL(_ name: String, _ ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Extensions")
    }

    static func prismPluginURL(_ name: String, _ ext: String) -> URL? {
        let dir = "\(prismPluginDirectory)/\(name)"
        return bundle.url(forResource: "prism-\(name).min", withExtension: ext,
                          subdirectory: dir)
            ?? bundle.url(forResource: "prism-\(name)", withExtension: ext,
                          subdirectory: dir)
    }

    static func prismScriptURLs(forLanguage language: String) -> [URL] {
        let language = language.lowercased()
        var base: URL?
        var extra: URL?
        for ext in ["min.js", "js"] {
            base = base ?? bundle.url(forResource: "prism-\(language)",
                                      withExtension: ext,
                                      subdirectory: prismScriptDirectory)
            extra = extra ?? bundle.url(forResource: "prism-\(language)-extras",
                                        withExtension: ext,
                                        subdirectory: prismScriptDirectory)
        }
        return [base, extra].compactMap { $0 }
    }

    // MARK: Asset groups

    static func baseStylesheets(_ s: PageSettings) -> [Asset] {
        guard let path = MPPaths.stylePath(forName: s.styleName) else { return [] }
        return [.css(path)]
    }

    static func prismStylesheets(_ s: PageSettings) -> [Asset] {
        var sheets: [Asset] = [.css(MPPaths.highlightingThemeURL(
            forName: s.highlightingThemeName))]
        if s.lineNumbers {
            sheets.append(.css(prismPluginURL("line-numbers", "css")))
        }
        if s.codeBlockAccessory == .languageName {
            sheets.append(.css(prismPluginURL("show-language", "css")))
        }
        return sheets
    }

    static func prismScripts(_ s: PageSettings, languages: [String]) -> [Asset] {
        var scripts: [Asset] = [.javaScript(bundle.url(
            forResource: "prism-core.min", withExtension: "js",
            subdirectory: prismScriptDirectory))]
        for language in languages {
            scripts += prismScriptURLs(forLanguage: language).map(Asset.javaScript)
        }
        if s.lineNumbers {
            scripts.append(.javaScript(prismPluginURL("line-numbers", "js")))
        }
        if s.codeBlockAccessory == .languageName {
            scripts.append(.javaScript(prismPluginURL("show-language", "js")))
        }
        return scripts
    }

    static func mathJaxScripts() -> [Asset] {
        [
            .embeddedScript(bundle.url(forResource: "init", withExtension: "js",
                                       subdirectory: "MathJax"),
                            type: AssetType.mathJaxConfig),
            .javaScript(mathJaxCDN),
        ]
    }

    static func mermaidStylesheets() -> [Asset] {
        [.css(extensionURL("mermaid", "css"))]
    }

    static func mermaidScripts() -> [Asset] {
        [.javaScript(extensionURL("mermaid.min", "js")),
         .javaScript(extensionURL("mermaid.init", "js"))]
    }

    static func graphvizScripts() -> [Asset] {
        [.javaScript(extensionURL("viz", "js")),
         .javaScript(extensionURL("viz.init", "js"))]
    }

    static func stylesheets(_ s: PageSettings) -> [Asset] {
        var sheets = baseStylesheets(s)
        if s.syntaxHighlighting {
            sheets += prismStylesheets(s)
            if s.mermaid { sheets += mermaidStylesheets() }
        }
        if s.codeBlockAccessory == .custom {
            sheets.append(.css(extensionURL("show-information", "css")))
        }
        return sheets
    }

    static func scripts(_ s: PageSettings, languages: [String]) -> [Asset] {
        var scripts: [Asset] = []
        if s.taskList {
            scripts.append(.javaScript(extensionURL("tasklist", "js")))
        }
        if s.syntaxHighlighting {
            scripts += prismScripts(s, languages: languages)
            if s.mermaid { scripts += mermaidScripts() }
            if s.graphviz { scripts += graphvizScripts() }
        }
        if s.mathJax { scripts += mathJaxScripts() }
        return scripts
    }

    // MARK: Pages

    nonisolated(unsafe) private static var templateCache: [String: HTMLTemplate] = [:]
    private static let templateLock = NSLock()

    static func template(named name: String) -> HTMLTemplate {
        templateLock.lock()
        defer { templateLock.unlock() }
        if let t = templateCache[name] { return t }
        let url = bundle.url(forResource: name, withExtension: "handlebars",
                             subdirectory: "Templates")
            ?? bundle.url(forResource: "Default", withExtension: "handlebars",
                          subdirectory: "Templates")
        let template = HTMLTemplate(url.map(MPPaths.readFile(at:)) ?? "{{{ body }}}")
        templateCache[name] = template
        return template
    }

    public static func html(title: String?, body: String, templateName: String,
                            styles: [Asset], styleOption: AssetOption,
                            scripts: [Asset], scriptOption: AssetOption,
                            linkTransform: (URL) -> URL = { $0 }) -> String {
        let styleTags = styles.compactMap {
            $0.html(for: styleOption, linkTransform: linkTransform)
        }
        let scriptTags = scripts.compactMap {
            $0.html(for: scriptOption, linkTransform: linkTransform)
        }
        let title = title ?? ""
        let titleTag = title.isEmpty ? "" : "<title>\(title)</title>"
        return template(named: templateName).render([
            "title": .string(title),
            "titleTag": .string(titleTag),
            "styleTags": .list(styleTags),
            "body": .string(body),
            "scriptTags": .list(scriptTags),
        ])
    }

    /// Comments around the body in preview pages, so the preview can
    /// replace the body without reloading the page.
    static let previewBodyStart = "<!--macdown-body-start-->"
    static let previewBodyEnd = "<!--macdown-body-end-->"

    /// The page shown in the preview, linking to all assets.
    public static func previewHTML(title: String?, result: ParseResult,
                                   settings: PageSettings,
                                   linkTransform: (URL) -> URL = { $0 }) -> String {
        let body = "\(previewBodyStart)\n\(result.body)\n\(previewBodyEnd)"
        return html(title: title, body: body, templateName: settings.templateName,
             styles: stylesheets(settings), styleOption: .fullLink,
             scripts: scripts(settings, languages: result.languages),
             scriptOption: .fullLink, linkTransform: linkTransform)
    }

    /// A self-contained page for export.
    public static func exportHTML(title: String?, result: ParseResult,
                                  settings: PageSettings, withStyles: Bool,
                                  withHighlighting: Bool) -> String {
        var stylesOption = AssetOption.none
        var scriptsOption = AssetOption.none
        var styles: [Asset] = []
        var scripts: [Asset] = []

        if withStyles {
            stylesOption = .embedded
            styles += baseStylesheets(settings)
        }
        if withHighlighting {
            stylesOption = .embedded
            scriptsOption = .embedded
            styles += prismStylesheets(settings)
            scripts += prismScripts(settings, languages: result.languages)
            if settings.mermaid {
                styles += mermaidStylesheets()
                scripts += mermaidScripts()
            }
            if settings.graphviz {
                scripts += graphvizScripts()
            }
        }
        if settings.mathJax {
            scriptsOption = .embedded
            scripts += mathJaxScripts()
        }
        return html(title: title ?? "", body: result.body,
                    templateName: settings.templateName,
                    styles: styles, styleOption: stylesOption,
                    scripts: scripts, scriptOption: scriptsOption)
    }
}

/// Keeps the latest parse result of a document, and re-parses in the
/// background when the text or relevant settings change.
@MainActor
public final class Renderer {
    public private(set) var result = ParseResult(body: "", languages: [])
    public private(set) var lastParseSettings: ParseSettings?
    public private(set) var lastPageSettings: PageSettings?

    private var parseTask: Task<Void, Never>?
    private var generation = 0

    public init() {}

    public var currentHTML: String { result.body }

    /// Parses synchronously on the calling actor.
    public func parseNow(_ markdown: String, settings: ParseSettings) {
        parseTask?.cancel()
        generation += 1
        result = MarkdownParser.parse(markdown, settings: settings)
        lastParseSettings = settings
    }

    /// Parses in the background, then calls `completion` on the main actor.
    /// A newer request supersedes older ones.
    public func parse(_ markdown: String, settings: ParseSettings,
                      completion: @escaping @MainActor () -> Void) {
        parseTask?.cancel()
        generation += 1
        let current = generation
        parseTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(markdown, settings: settings)
            }.value
            guard let self, !Task.isCancelled, current == self.generation else {
                return
            }
            self.result = result
            self.lastParseSettings = settings
            completion()
        }
    }

    public func markRendered(with settings: PageSettings) {
        lastPageSettings = settings
    }
}

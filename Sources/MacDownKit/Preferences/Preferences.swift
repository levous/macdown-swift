//
//  Preferences.swift
//  MacDown
//
//  Ported from MPPreferences.m. Preference keys are identical to the original
//  application's user defaults keys.
//

import AppKit
import Observation
import MacDownShared

public extension Notification.Name {
    /// Posted when a preference changes. `userInfo["key"]` holds the
    /// preference key.
    static let preferencesDidChange = Notification.Name("MPPreferencesDidChange")
    /// Posted on first launch after the preferences are initialized.
    static let didDetectFreshInstallation =
        Notification.Name("MPDidDetectFreshInstallationNotificationName")
    /// Requests editors to reapply their setup for `userInfo["key"]`.
    static let didRequestEditorSetup = Notification.Name("MPDidRequestEditorSetup")
    /// Requests previews to render again.
    static let didRequestPreviewRender = Notification.Name("MPDidRequestPreviewRender")
}

public enum UnorderedListMarkerType: Int, CaseIterable, Sendable {
    case asterisk = 0, plusSign, minusSign

    public var marker: String {
        switch self {
        case .asterisk: return "* "
        case .plusSign: return "+ "
        case .minusSign: return "- "
        }
    }

    public var title: String {
        switch self {
        case .asterisk: return String(localized: "* (Asterisk)")
        case .plusSign: return String(localized: "+ (Plus sign)")
        case .minusSign: return String(localized: "- (Minus sign)")
        }
    }
}

public enum CodeBlockAccessoryType: Int, CaseIterable, Sendable {
    case none = 0, languageName, custom

    public var title: String {
        switch self {
        case .none: return String(localized: "None")
        case .languageName: return String(localized: "Language name")
        case .custom: return String(localized: "Custom")
        }
    }
}

public enum WordCountType: Int, CaseIterable, Sendable {
    case words = 0, characters, charactersNoSpaces
}

@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    @ObservationIgnored public let defaults: UserDefaults
    @ObservationIgnored private var loading = false

    static let defaultEditorFontName = "Menlo-Regular"
    static let defaultEditorFontPointSize = 14.0

    // MARK: General

    public var firstVersionInstalled: String? { didSet { save(firstVersionInstalled, "firstVersionInstalled") } }
    public var latestVersionInstalled: String? { didSet { save(latestVersionInstalled, "latestVersionInstalled") } }
    public var supressesUntitledDocumentOnLaunch = false { didSet { save(supressesUntitledDocumentOnLaunch, "supressesUntitledDocumentOnLaunch") } }
    public var createFileForLinkTarget = false { didSet { save(createFileForLinkTarget, "createFileForLinkTarget") } }

    // MARK: Markdown extensions

    public var extensionIntraEmphasis = false { didSet { save(extensionIntraEmphasis, "extensionIntraEmphasis") } }
    public var extensionTables = false { didSet { save(extensionTables, "extensionTables") } }
    public var extensionFencedCode = false { didSet { save(extensionFencedCode, "extensionFencedCode") } }
    public var extensionAutolink = false { didSet { save(extensionAutolink, "extensionAutolink") } }
    public var extensionStrikethough = false { didSet { save(extensionStrikethough, "extensionStrikethough") } }
    public var extensionUnderline = false { didSet { save(extensionUnderline, "extensionUnderline") } }
    public var extensionSuperscript = false { didSet { save(extensionSuperscript, "extensionSuperscript") } }
    public var extensionHighlight = false { didSet { save(extensionHighlight, "extensionHighlight") } }
    public var extensionFootnotes = false { didSet { save(extensionFootnotes, "extensionFootnotes") } }
    public var extensionQuote = false { didSet { save(extensionQuote, "extensionQuote") } }
    public var extensionSmartyPants = false { didSet { save(extensionSmartyPants, "extensionSmartyPants") } }

    public var markdownManualRender = false { didSet { save(markdownManualRender, "markdownManualRender") } }

    // MARK: Editor

    public var editorBaseFontInfo: [String: Any] = [:] { didSet { save(editorBaseFontInfo, "editorBaseFontInfo") } }
    public var editorAutoIncrementNumberedLists = false { didSet { save(editorAutoIncrementNumberedLists, "editorAutoIncrementNumberedLists") } }
    public var editorConvertTabs = false { didSet { save(editorConvertTabs, "editorConvertTabs") } }
    public var editorInsertPrefixInBlock = false { didSet { save(editorInsertPrefixInBlock, "editorInsertPrefixInBlock") } }
    public var editorCompleteMatchingCharacters = false { didSet { save(editorCompleteMatchingCharacters, "editorCompleteMatchingCharacters") } }
    public var editorSyncScrolling = false { didSet { save(editorSyncScrolling, "editorSyncScrolling") } }
    public var editorSmartHome = false { didSet { save(editorSmartHome, "editorSmartHome") } }
    public var editorStyleName: String? { didSet { save(editorStyleName, "editorStyleName") } }
    public var editorHorizontalInset = 0.0 { didSet { save(editorHorizontalInset, "editorHorizontalInset") } }
    public var editorVerticalInset = 0.0 { didSet { save(editorVerticalInset, "editorVerticalInset") } }
    public var editorLineSpacing = 0.0 { didSet { save(editorLineSpacing, "editorLineSpacing") } }
    public var editorWidthLimited = false { didSet { save(editorWidthLimited, "editorWidthLimited") } }
    public var editorMaximumWidth = 0.0 { didSet { save(editorMaximumWidth, "editorMaximumWidth") } }
    public var editorOnRight = false { didSet { save(editorOnRight, "editorOnRight") } }
    public var editorShowWordCount = false { didSet { save(editorShowWordCount, "editorShowWordCount") } }
    public var editorWordCountType = 0 { didSet { save(editorWordCountType, "editorWordCountType") } }
    public var editorScrollsPastEnd = false { didSet { save(editorScrollsPastEnd, "editorScrollsPastEnd") } }
    public var editorEnsuresNewlineAtEndOfFile = false { didSet { save(editorEnsuresNewlineAtEndOfFile, "editorEnsuresNewlineAtEndOfFile") } }
    public var editorUnorderedListMarkerType = 0 { didSet { save(editorUnorderedListMarkerType, "editorUnorderedListMarkerType") } }

    public var previewZoomRelativeToBaseFontSize = false { didSet { save(previewZoomRelativeToBaseFontSize, "previewZoomRelativeToBaseFontSize") } }

    // MARK: HTML rendering

    public var htmlTemplateName: String? { didSet { save(htmlTemplateName, "htmlTemplateName") } }
    public var htmlStyleName: String? { didSet { save(htmlStyleName, "htmlStyleName") } }
    public var htmlDetectFrontMatter = false { didSet { save(htmlDetectFrontMatter, "htmlDetectFrontMatter") } }
    public var htmlTaskList = false { didSet { save(htmlTaskList, "htmlTaskList") } }
    public var htmlHardWrap = false { didSet { save(htmlHardWrap, "htmlHardWrap") } }
    public var htmlMathJax = false { didSet { save(htmlMathJax, "htmlMathJax") } }
    public var htmlMathJaxInlineDollar = false { didSet { save(htmlMathJaxInlineDollar, "htmlMathJaxInlineDollar") } }
    public var htmlSyntaxHighlighting = false { didSet { save(htmlSyntaxHighlighting, "htmlSyntaxHighlighting") } }
    public var htmlHighlightingThemeName: String? { didSet { save(htmlHighlightingThemeName, "htmlHighlightingThemeName") } }
    public var htmlLineNumbers = false { didSet { save(htmlLineNumbers, "htmlLineNumbers") } }
    public var htmlGraphviz = false { didSet { save(htmlGraphviz, "htmlGraphviz") } }
    public var htmlMermaid = false { didSet { save(htmlMermaid, "htmlMermaid") } }
    public var htmlCodeBlockAccessory = 0 { didSet { save(htmlCodeBlockAccessory, "htmlCodeBlockAccessory") } }
    public var htmlDefaultDirectoryUrl: URL? {
        didSet {
            guard !loading else { return }
            defaults.set(htmlDefaultDirectoryUrl, forKey: "htmlDefaultDirectoryUrl")
            changed("htmlDefaultDirectoryUrl")
        }
    }
    public var htmlRendersTOC = false { didSet { save(htmlRendersTOC, "htmlRendersTOC") } }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cleanupObsoleteAutosaveValues()
        load()

        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? MacDownGlobals.bundleVersion

        // This is a fresh install. Set default preferences.
        if firstVersionInstalled == nil {
            firstVersionInstalled = version
            loadDefaultPreferences()
            // Post after the initializer finishes so others can listen.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .didDetectFreshInstallation, object: nil)
            }
        }
        loadDefaultUserDefaults()
        latestVersionInstalled = version
    }

    // MARK: - Calculated values

    public var editorBaseFontName: String? {
        editorBaseFontInfo["name"] as? String
    }

    public var editorBaseFontSize: Double {
        (editorBaseFontInfo["size"] as? NSNumber)?.doubleValue ?? 0
    }

    public var editorBaseFont: NSFont? {
        get {
            guard let name = editorBaseFontName else { return nil }
            return NSFont(name: name, size: editorBaseFontSize)
        }
        set {
            guard let font = newValue else { return }
            editorBaseFontInfo = ["name": font.fontName, "size": font.pointSize]
        }
    }

    public var editorUnorderedListMarker: String {
        (UnorderedListMarkerType(rawValue: editorUnorderedListMarkerType)
            ?? .asterisk).marker
    }

    public var codeBlockAccessory: CodeBlockAccessoryType {
        CodeBlockAccessoryType(rawValue: htmlCodeBlockAccessory) ?? .none
    }

    // MARK: - Files handed over by the shell utility

    /// The suite shared with the shell utility. Inside the application this
    /// is the app's own domain, i.e. the standard defaults.
    private var suiteDefaults: UserDefaults? {
        if Bundle.main.bundleIdentifier == MacDownGlobals.applicationSuiteName {
            return .standard
        }
        return UserDefaults(suiteName: MacDownGlobals.applicationSuiteName)
    }

    public var filesToOpen: [String]? {
        get { suiteDefaults?.stringArray(forKey: MacDownGlobals.filesToOpenKey) }
        set { suiteDefaults?.set(newValue, forKey: MacDownGlobals.filesToOpenKey) }
    }

    public var pipedContentFileToOpen: String? {
        get { suiteDefaults?.string(forKey: MacDownGlobals.pipedContentFileToOpenKey) }
        set { suiteDefaults?.set(newValue, forKey: MacDownGlobals.pipedContentFileToOpenKey) }
    }

    public func synchronize() {
        suiteDefaults?.synchronize()
    }

    // MARK: - Private

    private func save(_ value: Any?, _ key: String) {
        guard !loading else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        changed(key)
    }

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: .preferencesDidChange, object: self,
                                        userInfo: ["key": key])
    }

    /// Reads all values from user defaults.
    public func load() {
        loading = true
        defer { loading = false }
        let d = defaults
        firstVersionInstalled = d.string(forKey: "firstVersionInstalled")
        latestVersionInstalled = d.string(forKey: "latestVersionInstalled")
        supressesUntitledDocumentOnLaunch = d.bool(forKey: "supressesUntitledDocumentOnLaunch")
        createFileForLinkTarget = d.bool(forKey: "createFileForLinkTarget")

        extensionIntraEmphasis = d.bool(forKey: "extensionIntraEmphasis")
        extensionTables = d.bool(forKey: "extensionTables")
        extensionFencedCode = d.bool(forKey: "extensionFencedCode")
        extensionAutolink = d.bool(forKey: "extensionAutolink")
        extensionStrikethough = d.bool(forKey: "extensionStrikethough")
        extensionUnderline = d.bool(forKey: "extensionUnderline")
        extensionSuperscript = d.bool(forKey: "extensionSuperscript")
        extensionHighlight = d.bool(forKey: "extensionHighlight")
        extensionFootnotes = d.bool(forKey: "extensionFootnotes")
        extensionQuote = d.bool(forKey: "extensionQuote")
        extensionSmartyPants = d.bool(forKey: "extensionSmartyPants")
        markdownManualRender = d.bool(forKey: "markdownManualRender")

        editorBaseFontInfo = d.dictionary(forKey: "editorBaseFontInfo") ?? [:]
        editorAutoIncrementNumberedLists = d.bool(forKey: "editorAutoIncrementNumberedLists")
        editorConvertTabs = d.bool(forKey: "editorConvertTabs")
        editorInsertPrefixInBlock = d.bool(forKey: "editorInsertPrefixInBlock")
        editorCompleteMatchingCharacters = d.bool(forKey: "editorCompleteMatchingCharacters")
        editorSyncScrolling = d.bool(forKey: "editorSyncScrolling")
        editorSmartHome = d.bool(forKey: "editorSmartHome")
        editorStyleName = d.string(forKey: "editorStyleName")
        editorHorizontalInset = d.double(forKey: "editorHorizontalInset")
        editorVerticalInset = d.double(forKey: "editorVerticalInset")
        editorLineSpacing = d.double(forKey: "editorLineSpacing")
        editorWidthLimited = d.bool(forKey: "editorWidthLimited")
        editorMaximumWidth = d.double(forKey: "editorMaximumWidth")
        editorOnRight = d.bool(forKey: "editorOnRight")
        editorShowWordCount = d.bool(forKey: "editorShowWordCount")
        editorWordCountType = d.integer(forKey: "editorWordCountType")
        editorScrollsPastEnd = d.bool(forKey: "editorScrollsPastEnd")
        editorEnsuresNewlineAtEndOfFile = d.bool(forKey: "editorEnsuresNewlineAtEndOfFile")
        editorUnorderedListMarkerType = d.integer(forKey: "editorUnorderedListMarkerType")
        previewZoomRelativeToBaseFontSize = d.bool(forKey: "previewZoomRelativeToBaseFontSize")

        htmlTemplateName = d.string(forKey: "htmlTemplateName")
        htmlStyleName = d.string(forKey: "htmlStyleName")
        htmlDetectFrontMatter = d.bool(forKey: "htmlDetectFrontMatter")
        htmlTaskList = d.bool(forKey: "htmlTaskList")
        htmlHardWrap = d.bool(forKey: "htmlHardWrap")
        htmlMathJax = d.bool(forKey: "htmlMathJax")
        htmlMathJaxInlineDollar = d.bool(forKey: "htmlMathJaxInlineDollar")
        htmlSyntaxHighlighting = d.bool(forKey: "htmlSyntaxHighlighting")
        htmlHighlightingThemeName = d.string(forKey: "htmlHighlightingThemeName")
        htmlLineNumbers = d.bool(forKey: "htmlLineNumbers")
        htmlGraphviz = d.bool(forKey: "htmlGraphviz")
        htmlMermaid = d.bool(forKey: "htmlMermaid")
        htmlCodeBlockAccessory = d.integer(forKey: "htmlCodeBlockAccessory")
        htmlDefaultDirectoryUrl = d.url(forKey: "htmlDefaultDirectoryUrl")
        htmlRendersTOC = d.bool(forKey: "htmlRendersTOC")
    }

    private func cleanupObsoleteAutosaveValues() {
        var keysToRemove: [String] = []
        for key in defaults.dictionaryRepresentation().keys {
            for p in ["NSSplitView Subview Frames", "NSWindow Frame"] {
                guard key.hasPrefix(p), key.count >= p.count + 1 else { continue }
                let path = String(key.dropFirst(p.count + 1))
                guard let url = URL(string: path), url.isFileURL else { continue }
                if !FileManager.default.fileExists(atPath: url.path) {
                    keysToRemove.append(key)
                }
                break
            }
        }
        keysToRemove.forEach(defaults.removeObject(forKey:))
    }

    /// Load app-default preferences on first launch.
    ///
    /// New preferences that break backward compatibility should NOT be put
    /// here, since existing users won't have this invoked when upgrading.
    /// See `loadDefaultUserDefaults()`.
    private func loadDefaultPreferences() {
        extensionIntraEmphasis = true
        extensionTables = true
        extensionFencedCode = true
        extensionFootnotes = true
        editorBaseFontInfo = [
            "name": Self.defaultEditorFontName,
            "size": Self.defaultEditorFontPointSize,
        ]
        editorStyleName = "Tomorrow+"
        editorHorizontalInset = 15.0
        editorVerticalInset = 30.0
        editorLineSpacing = 3.0
        editorSyncScrolling = true
        htmlStyleName = "GitHub2"
        htmlSyntaxHighlighting = true
        htmlMermaid = true
        htmlDefaultDirectoryUrl = URL(fileURLWithPath: NSHomeDirectory(),
                                      isDirectory: true)
    }

    /// Load default preferences every time the app launches. Suitable for
    /// backward-compatibility checks.
    private func loadDefaultUserDefaults() {
        if defaults.object(forKey: "editorMaximumWidth") == nil {
            editorMaximumWidth = 1000.0
        }
        if defaults.object(forKey: "editorAutoIncrementNumberedLists") == nil {
            editorAutoIncrementNumberedLists = true
        }
        if defaults.object(forKey: "editorInsertPrefixInBlock") == nil {
            editorInsertPrefixInBlock = true
        }
        if defaults.object(forKey: "htmlTemplateName") == nil {
            htmlTemplateName = "Default"
        }
    }
}

//
//  PreferenceSettingKey.swift
//  MacDownKit
//
//  The user defaults keys of MacDown's preferences. Raw values are the
//  original app's keys and must not change (CLAUDE.md).
//

import AppKit
import Foundation

public enum PreferenceSettingKey: String, CaseIterable, Sendable {
    // MARK: General
    case firstVersionInstalled
    case latestVersionInstalled
    case supressesUntitledDocumentOnLaunch
    case createFileForLinkTarget
    case autosavesDocuments

    // MARK: Markdown
    case extensionAutolink
    case extensionSuperscript
    case extensionHighlight
    case extensionSmartyPants
    case markdownManualRender
    /// Hidden: the Markdown engine (cmark-gfm or hoedown).
    case markdownEngine

    // MARK: Editor
    case editorBaseFontInfo
    case editorAutoIncrementNumberedLists
    case editorConvertTabs
    case editorInsertPrefixInBlock
    case editorCompleteMatchingCharacters
    case editorSyncScrolling
    case editorSmartHome
    case editorStyleName
    case editorHorizontalInset
    case editorVerticalInset
    case editorLineSpacing
    case editorWidthLimited
    case editorMaximumWidth
    case editorOnRight
    case editorShowWordCount
    case editorWordCountType
    case editorScrollsPastEnd
    case editorEnsuresNewlineAtEndOfFile
    case editorUnorderedListMarkerType

    // MARK: Editor text checking (NSTextView settings, see `textViewKeyPath`)
    case editorAutomaticDashSubstitutionEnabled
    case editorAutomaticDataDetectionEnabled
    case editorAutomaticQuoteSubstitutionEnabled
    case editorAutomaticSpellingCorrectionEnabled
    case editorAutomaticTextReplacementEnabled
    case editorContinuousSpellCheckingEnabled
    case editorEnabledTextCheckingTypes
    case editorGrammarCheckingEnabled

    // MARK: Rendering
    case previewZoomRelativeToBaseFontSize
    case htmlTemplateName
    case htmlStyleName
    case htmlHardWrap
    case htmlMathJax
    case htmlMathJaxInlineDollar
    case htmlSyntaxHighlighting
    case htmlHighlightingThemeName
    case htmlLineNumbers
    case htmlGraphviz
    case htmlMermaid
    case htmlCodeBlockAccessory
    case htmlDefaultDirectoryUrl
    case htmlRendersTOC

    // MARK: Retired
    // Settings that are no longer read: standard Markdown is always on, and
    // Quote and Underline are gone. Their saved values are left in place
    // (FR-36), so a downgrade still finds them.
    case extensionTables
    case extensionFencedCode
    case extensionFootnotes
    case extensionStrikethough
    case extensionIntraEmphasis
    case extensionQuote
    case extensionUnderline
    case htmlTaskList
    case htmlDetectFrontMatter

    public static let retired: [PreferenceSettingKey] = [
        .extensionTables, .extensionFencedCode, .extensionFootnotes, .extensionStrikethough,
        .extensionIntraEmphasis, .extensionQuote, .extensionUnderline, .htmlTaskList,
        .htmlDetectFrontMatter,
    ]

    /// The editor's text checking settings: each `NSTextView` key path,
    /// the preference that persists it, and its default.
    static let textChecking: [(textViewKeyPath: String, key: PreferenceSettingKey, defaultValue: any Sendable)] = [
        ("automaticDashSubstitutionEnabled", .editorAutomaticDashSubstitutionEnabled, false),
        ("automaticDataDetectionEnabled", .editorAutomaticDataDetectionEnabled, false),
        ("automaticQuoteSubstitutionEnabled", .editorAutomaticQuoteSubstitutionEnabled, false),
        ("automaticSpellingCorrectionEnabled", .editorAutomaticSpellingCorrectionEnabled, false),
        ("automaticTextReplacementEnabled", .editorAutomaticTextReplacementEnabled, false),
        ("continuousSpellCheckingEnabled", .editorContinuousSpellCheckingEnabled, false),
        ("enabledTextCheckingTypes", .editorEnabledTextCheckingTypes, NSTextCheckingAllTypes),
        ("grammarCheckingEnabled", .editorGrammarCheckingEnabled, false),
    ]
}

public extension Notification {
    /// The `userInfo` key under which preference notifications carry their
    /// `PreferenceSettingKey`.
    static let preferenceKeyUserInfoKey = "key"

    /// The preference a `.preferencesDidChange` or `.didRequestEditorSetup`
    /// notification is about.
    var preferenceKey: PreferenceSettingKey? {
        userInfo?[Self.preferenceKeyUserInfoKey] as? PreferenceSettingKey
    }
}

extension UserDefaults {
    func object(forKey key: PreferenceSettingKey) -> Any? { object(forKey: key.rawValue) }
    func bool(forKey key: PreferenceSettingKey) -> Bool { bool(forKey: key.rawValue) }
    func integer(forKey key: PreferenceSettingKey) -> Int { integer(forKey: key.rawValue) }
    func double(forKey key: PreferenceSettingKey) -> Double { double(forKey: key.rawValue) }
    func string(forKey key: PreferenceSettingKey) -> String? { string(forKey: key.rawValue) }
    func url(forKey key: PreferenceSettingKey) -> URL? { url(forKey: key.rawValue) }
    func dictionary(forKey key: PreferenceSettingKey) -> [String: Any]? {
        dictionary(forKey: key.rawValue)
    }
    func set(_ value: Any?, forKey key: PreferenceSettingKey) { set(value, forKey: key.rawValue) }
    func set(_ url: URL?, forKey key: PreferenceSettingKey) { set(url, forKey: key.rawValue) }
    func removeObject(forKey key: PreferenceSettingKey) { removeObject(forKey: key.rawValue) }
}

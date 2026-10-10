//
//  SettingsView.swift
//  MacDown
//
//  The Settings window, replacing the MASPreferences panes (General,
//  Markdown, Editor, Rendering, Terminal).
//

import AppKit
import MacDownShared
import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", image: "PreferencesGeneral") }
            MarkdownSettingsView()
                .tabItem { Label("Markdown", image: "PreferencesMarkdown") }
            EditorSettingsView()
                .tabItem { Label("Editor", image: "PreferencesEditor") }
            RenderingSettingsView()
                .tabItem { Label("Rendering", image: "PreferencesRendering") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", image: "PreferencesTerminal") }
        }
        .frame(width: 520)
    }
}

/// Binding that inverts a Boolean preference (NSNegateBoolean).
private func negated(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { !binding.wrappedValue }, set: { binding.wrappedValue = !$0 })
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Toggle("Update preview automatically as you type",
                   isOn: negated($preferences.markdownManualRender))
            Toggle("Sync preview scrollbar when editor scrolls",
                   isOn: $preferences.editorSyncScrolling)
            Toggle("Put editor on the right", isOn: $preferences.editorOnRight)
            Toggle("Show word count", isOn: $preferences.editorShowWordCount)
                .disabled(preferences.markdownManualRender)
            Toggle("Ensure open document on launch",
                   isOn: negated($preferences.supressesUntitledDocumentOnLaunch))
            Toggle("Automatically create files for link targets",
                   isOn: $preferences.createFileForLinkTarget)
            Toggle("Save changes automatically", isOn: $preferences.autosavesDocuments)
        }
        .padding(20)
    }
}

// MARK: - Markdown

struct MarkdownSettingsView: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            // Standard Markdown (tables, fenced code, footnotes,
            // strikethrough, task lists) is always on; these are extensions.
            Section("Inline formatting:") {
                Toggle("Highlight", isOn: $preferences.extensionHighlight)
                Toggle("Superscript", isOn: $preferences.extensionSuperscript)
                Toggle("Autolink", isOn: $preferences.extensionAutolink)
                Toggle("Smart punctuation", isOn: $preferences.extensionSmartyPants)
            }
        }
        .padding(20)
    }
}

// MARK: - Editor

/// Receives font panel changes.
@MainActor
final class FontPanelCoordinator: NSObject {
    static let shared = FontPanelCoordinator()

    func show() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        if let font = Preferences.shared.editorBaseFont {
            manager.setSelectedFont(font, isMultiple: false)
        }
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let base = Preferences.shared.editorBaseFont ?? .userFixedPitchFont(ofSize: 14)!
        Preferences.shared.editorBaseFont = sender.convert(base)
    }
}

struct EditorSettingsView: View {
    @Bindable private var preferences = Preferences.shared
    @State private var themes: [String] = []

    private var fontDescription: String {
        guard let font = preferences.editorBaseFont else { return "—" }
        return String(format: "%@ - %.1f", font.displayName ?? font.fontName,
                      font.pointSize)
    }

    private var themeSelection: Binding<String> {
        Binding(get: { preferences.editorStyleName ?? "" },
                set: { preferences.editorStyleName = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            LabeledContent("Base font:") {
                HStack {
                    Text(fontDescription)
                        .font(preferences.editorBaseFont.map { Font($0) })
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") { FontPanelCoordinator.shared.show() }
                }
            }
            LabeledContent("Theme:") {
                HStack {
                    Picker("Theme", selection: themeSelection) {
                        Text("").tag("")
                        ForEach(themes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    DataDirectoryButtons(directory: MPPaths.themesDirectoryName) {
                        loadThemes()
                        NotificationCenter.default.post(
                            name: .didRequestEditorSetup, object: nil,
                            userInfo: [Notification.preferenceKeyUserInfoKey:
                                        PreferenceSettingKey.editorStyleName])
                    }
                }
            }
            LabeledContent("Text insets:") {
                HStack {
                    NumberField(value: $preferences.editorHorizontalInset)
                    Text("×")
                    NumberField(value: $preferences.editorVerticalInset)
                }
            }
            LabeledContent("Line spacing:") {
                NumberField(value: $preferences.editorLineSpacing, step: 0.5)
            }
            LabeledContent("Limit editor width to") {
                HStack {
                    Toggle("Limit editor width", isOn: $preferences.editorWidthLimited)
                        .labelsHidden()
                    NumberField(value: $preferences.editorMaximumWidth, step: 10)
                        .disabled(!preferences.editorWidthLimited)
                }
            }
            Picker("List marker:", selection: $preferences.editorUnorderedListMarkerType) {
                ForEach(UnorderedListMarkerType.allCases, id: \.rawValue) {
                    Text($0.title).tag($0.rawValue)
                }
            }
            Section {
                Toggle("Automatically insert line prefix for the current block",
                       isOn: $preferences.editorInsertPrefixInBlock)
                Toggle("Auto-increment numbering in ordered lists",
                       isOn: $preferences.editorAutoIncrementNumberedLists)
                    .disabled(!preferences.editorInsertPrefixInBlock)
                    .padding(.leading, 18)
                Toggle("Insert spaces instead of tabs", isOn: $preferences.editorConvertTabs)
                Toggle("Auto-complete matching characters",
                       isOn: $preferences.editorCompleteMatchingCharacters)
                Toggle("⌘← jumps to first non-whitespace character in line",
                       isOn: $preferences.editorSmartHome)
                Toggle("Scroll past end", isOn: $preferences.editorScrollsPastEnd)
                Toggle("Ensure newline at end of file on save",
                       isOn: $preferences.editorEnsuresNewlineAtEndOfFile)
            }
        }
        .padding(20)
        .onAppear(perform: loadThemes)
    }

    private func loadThemes() {
        themes = MPPaths.listEntries(inDirectory: MPPaths.themesDirectoryName,
                                     withExtension: MPPaths.themeFileExtension).sorted()
    }
}

struct NumberField: View {
    @Binding var value: Double
    var step: Double = 1

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Stepper("", value: $value, in: 0...10_000, step: step)
                .labelsHidden()
        }
    }
}

/// "Reveal" and "Reload" buttons for a data directory.
struct DataDirectoryButtons: View {
    let directory: String
    let reload: () -> Void

    var body: some View {
        ControlGroup {
            Button {
                let url = MPPaths.dataDirectory(directory)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal")
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
        }
        .fixedSize()
    }
}

// MARK: - Rendering

struct RenderingSettingsView: View {
    @Bindable private var preferences = Preferences.shared
    @State private var styles: [String] = []

    private static let defaultThemeTitle = String(localized: "(Default)")

    private var styleSelection: Binding<String> {
        Binding(get: { preferences.htmlStyleName ?? "" },
                set: { preferences.htmlStyleName = $0.isEmpty ? nil : $0 })
    }

    private var themeSelection: Binding<String> {
        Binding(get: {
            let name = preferences.htmlHighlightingThemeName ?? ""
            return name.isEmpty ? Self.defaultThemeTitle : name
        }, set: {
            preferences.htmlHighlightingThemeName = $0 == Self.defaultThemeTitle ? "" : $0
        })
    }

    var body: some View {
        Form {
            LabeledContent("CSS:") {
                HStack {
                    Picker("CSS", selection: styleSelection) {
                        Text("").tag("")
                        ForEach(styles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    DataDirectoryButtons(directory: MPPaths.stylesDirectoryName) {
                        loadStyles()
                        NotificationCenter.default.post(name: .didRequestPreviewRender,
                                                        object: nil)
                    }
                }
            }
            LabeledContent("Default path:") {
                HStack {
                    Text(preferences.htmlDefaultDirectoryUrl?.path ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: chooseDefaultDirectory)
                }
            }
            Section {
                Toggle("Syntax highlighted code block",
                       isOn: $preferences.htmlSyntaxHighlighting)
                Group {
                    Picker("Theme:", selection: themeSelection) {
                        Text(Self.defaultThemeTitle).tag(Self.defaultThemeTitle)
                        ForEach(MPPaths.highlightingThemeNames(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Toggle("Show line numbers", isOn: $preferences.htmlLineNumbers)
                    HStack {
                        Toggle("Graphviz", isOn: $preferences.htmlGraphviz)
                        Toggle("Mermaid", isOn: $preferences.htmlMermaid)
                    }
                    Picker("Accessory:", selection: $preferences.htmlCodeBlockAccessory) {
                        ForEach(CodeBlockAccessoryType.allCases, id: \.rawValue) {
                            Text($0.title).tag($0.rawValue)
                        }
                    }
                }
                .disabled(!preferences.htmlSyntaxHighlighting)
                .padding(.leading, 18)
            }
            Section {
                Toggle("TeX-like math syntax", isOn: $preferences.htmlMathJax)
                Toggle("Use dollar sign ($) as inline delimiter",
                       isOn: $preferences.htmlMathJaxInlineDollar)
                    .disabled(!preferences.htmlMathJax)
                    .padding(.leading, 18)
                Text("Math support requires Internet connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Detect table of contents token", isOn: $preferences.htmlRendersTOC)
                Toggle("Render newline literally", isOn: $preferences.htmlHardWrap)
                Toggle("Scale preview based on editor font size",
                       isOn: $preferences.previewZoomRelativeToBaseFontSize)
            }
        }
        .padding(20)
        .onAppear(perform: loadStyles)
    }

    private func loadStyles() {
        styles = MPPaths.listEntries(inDirectory: MPPaths.stylesDirectoryName,
                                     withExtension: MPPaths.styleFileExtension).sorted()
    }

    private func chooseDefaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.htmlDefaultDirectoryUrl
        if panel.runModal() == .OK, let url = panel.url {
            preferences.htmlDefaultDirectoryUrl = url
        }
    }
}

// MARK: - Terminal

struct TerminalSettingsView: View {
    @State private var shellUtilityURL: URL?
    @State private var errorMessage: String?

    private static let installedColor = Color(red: 0.357, green: 0.659, blue: 0.192)
    private static let uninstalledColor = Color(red: 0.897, green: 0.231, blue: 0.21)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("●")
                    .foregroundStyle(shellUtilityURL != nil
                                     ? Self.installedColor : Self.uninstalledColor)
                Text(LocalizedStringKey(shellUtilityURL != nil
                                        ? "Shell utility installed"
                                        : "Shell utility not installed"))
                    .font(.headline)
            }
            Text("By activating shell support you can use the macdown utility to open MacDown and documents from a shell.")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Location:") {
                if let url = shellUtilityURL {
                    Text(url.path).font(.body.monospaced()).textSelection(.enabled)
                } else {
                    Text("<Not installed>").italic()
                }
            }
            HStack {
                Spacer()
                if shellUtilityURL != nil {
                    Button("Uninstall", action: uninstall)
                } else {
                    Button("Install", action: install)
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(20)
        .task { await lookForShellUtility() }
    }

    private var bundledUtilityPath: String? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("bin/macdown").path
    }

    private func lookForShellUtility() async {
        var path = MacDownGlobals.commandInstallationPath
        if let prefix = await ShellUtility.homebrewPrefix() {
            path = (prefix as NSString).appendingPathComponent("bin/macdown")
        }
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default
        if manager.fileExists(atPath: path)
            || (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            shellUtilityURL = url
        } else if manager.fileExists(atPath: MacDownGlobals.commandInstallationPath) {
            shellUtilityURL = URL(fileURLWithPath: MacDownGlobals.commandInstallationPath)
        } else {
            shellUtilityURL = nil
        }
    }

    private func install() {
        errorMessage = nil
        guard let source = bundledUtilityPath,
              FileManager.default.fileExists(atPath: source)
        else {
            errorMessage = String(localized: "The shell utility is missing from the application bundle.")
            return
        }
        do {
            try FileManager.default.createSymbolicLink(
                atPath: MacDownGlobals.commandInstallationPath,
                withDestinationPath: source)
            Task { await lookForShellUtility() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uninstall() {
        errorMessage = nil
        guard let url = shellUtilityURL else { return }
        do {
            try FileManager.default.removeItem(at: url)
            shellUtilityURL = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum ShellUtility {
    /// Output of `brew --prefix`, or nil if Homebrew isn't installed.
    static func homebrewPrefix() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                guard let brew = candidates.first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else {
                    continuation.resume(returning: nil)
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["--prefix"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: output?.isEmpty == false ? output : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

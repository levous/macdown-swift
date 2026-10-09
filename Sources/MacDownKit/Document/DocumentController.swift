//
//  DocumentController.swift
//  MacDown
//
//  Ported from MPDocument.m. One controller per document window; it owns the
//  editor, highlighter, renderer and preview, and implements every editing
//  and view action.
//

import AppKit
import CPegMarkdown
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
public final class DocumentController: NSObject {
    // MARK: Model

    public private(set) var document: MarkdownDocument
    public var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            if needsHtml { parseAndRender() }
            // Saving an untitled document gives it a file.
            updateUnsavedState()
        }
    }

    // MARK: Observable UI state

    /// Fraction of the window width used by the editor (0 = hidden editor,
    /// 1 = hidden preview).
    public var editorFraction: CGFloat = 0.5
    /// Background color of the editor theme.
    public var editorBackgroundColor: NSColor = .textBackgroundColor
    /// Divider color; nil draws the default divider.
    public var dividerColor: NSColor?
    /// Background color of the preview page, which the divider's drag area
    /// extends.
    public var previewBackgroundColor: NSColor = .white
    public var textCount = TextCount()
    public var isTextCountReady = false
    public var editorOnRight: Bool
    public var showsWordCount: Bool
    /// Whether the editor's draft differs from the saved document, or the
    /// document is untitled and not empty. Only
    /// with "Save changes automatically" off; otherwise every edit goes to
    /// the document, which AppKit autosaves.
    public private(set) var hasUnsavedChanges = false

    public var editorVisible: Bool { editorFraction > 0.001 }
    public var previewVisible: Bool { editorFraction < 0.999 }
    public var canRestorePreview: Bool { previewVisible || previousEditorFraction >= 0 }

    // MARK: Components

    @ObservationIgnored public let editorScrollView: NSScrollView
    @ObservationIgnored public let editor: EditorTextView
    @ObservationIgnored public let preview = PreviewController()
    @ObservationIgnored let highlighter = MarkdownHighlighter()
    @ObservationIgnored let renderer = Renderer()
    @ObservationIgnored var preferences: Preferences { .shared }
    /// The editor's undo manager. It's the controller's own rather than the
    /// window's (SwiftUI's), so typing doesn't mark the document changed;
    /// see "Draft".
    @ObservationIgnored public let undoManager = UndoManager()

    // MARK: Private state

    @ObservationIgnored private var previousEditorFraction: CGFloat = -1
    @ObservationIgnored private var manualRender = false
    @ObservationIgnored private var copying = false
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var shouldHandleBoundsChange = true
    @ObservationIgnored private var inLiveScroll = false
    @ObservationIgnored private(set) var editorAnchors: [ScrollAnchor] = []
    @ObservationIgnored private var editorTextEnd: CGFloat = 0
    /// What `editorAnchors` were computed for, to skip recomputing them.
    @ObservationIgnored private var editorLayoutSyncScheduled = false
    @ObservationIgnored private var editorAnchorsKey: (text: String, width: CGFloat,
                                                       frontMatter: Bool, fencedCode: Bool)?
    @ObservationIgnored private(set) var previewMetrics = PreviewMetrics()
    /// The pane the user scrolled last; the other one follows it.
    @ObservationIgnored private var scrollLeader = ScrollLeader.editor
    /// The last scroll offset set on the preview, and when, so the scroll
    /// events it causes aren't taken for the user scrolling the preview.
    @ObservationIgnored private var previewScrollTarget: (y: CGFloat, date: Date)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isSetUp = false

    /// Text checking settings of the editor persisted to user defaults, with
    /// their default values.
    private static let editorKeysToObserve: [(String, Any)] = [
        ("automaticDashSubstitutionEnabled", false),
        ("automaticDataDetectionEnabled", false),
        ("automaticQuoteSubstitutionEnabled", false),
        ("automaticSpellingCorrectionEnabled", false),
        ("automaticTextReplacementEnabled", false),
        ("continuousSpellCheckingEnabled", false),
        ("enabledTextCheckingTypes", NSTextCheckingAllTypes),
        ("grammarCheckingEnabled", false),
    ]

    private static let editorPreferencesToObserve: Set<String> = [
        "editorBaseFontInfo", "extensionFootnotes", "editorHorizontalInset",
        "editorVerticalInset", "editorWidthLimited", "editorMaximumWidth",
        "editorLineSpacing", "editorOnRight", "editorStyleName",
        "editorShowWordCount", "editorScrollsPastEnd",
    ]

    private static func preferenceKey(forEditorKey key: String) -> String {
        guard let first = key.first else { return "editor" }
        return "editor" + first.uppercased() + key.dropFirst()
    }

    // MARK: - Init

    public init(document: MarkdownDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        savedText = document.text
        (editorScrollView, editor) = EditorTextView.makeScrollableEditor()
        editorOnRight = Preferences.shared.editorOnRight
        showsWordCount = Preferences.shared.editorShowWordCount
        super.init()

        highlighter.textView = editor
        editor.delegate = self
        editor.string = document.text
        editor.frameDidChange = { [weak self] _ in
            guard let self else { return }
            if self.preferences.editorWidthLimited { self.adjustEditorInsets() }
            self.editorLayoutDidChange()
        }

        preview.onLoadFinished = { [weak self] in self?.previewDidFinishLoading() }
        preview.onOpenURL = { [weak self] url in self?.openOrCreateFile(for: url) }
        preview.onScroll = { [weak self] y in self?.previewDidScroll(to: y) }
        preview.onLayoutChange = { [weak self] in self?.previewLayoutDidChange() }

        setUpObservers()
        Self.register(self)
    }

    /// Finishes setup once the views are installed in a window, so the editor
    /// has its final dimensions for width limiting.
    public func viewDidAppear() {
        attachToWindow()
        guard !isSetUp else { return }
        isSetUp = true
        setupEditor(nil)
        parseAndRenderNow()
        highlighter.parseAndHighlightNow()
    }

    /// Replaces the model, e.g. after "Revert to Saved".
    /// Replaces the model, e.g. when the file changed on disk. A draft with
    /// unsaved changes is kept (now unsaved relative to the new text).
    public func replaceDocument(_ newDocument: MarkdownDocument) {
        guard newDocument !== document else { return }
        document = newDocument
        let keepsDraft = hasUnsavedChanges
        savedText = newDocument.text
        if !keepsDraft && editor.string != newDocument.text {
            editor.string = newDocument.text
            highlighter.parseAndHighlightNow()
            parseAndRenderNow()
        }
        updateUnsavedState()
    }

    public func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        keyObservers.removeAll()
        highlighter.deactivate()
        highlighter.textView = nil
        preview.onLoadFinished = nil
        preview.onOpenURL = nil
        preview.onScroll = nil
        preview.onLayoutChange = nil
        closeGuard?.uninstall(from: attachedWindow)
        closeGuard = nil
        responder?.uninstall()
        responder = nil
        Self.unregister(self)
    }

    private func setUpObservers() {
        let center = NotificationCenter.default
        // Handlers receive the notification's "key" user info value.
        func observe(_ name: Notification.Name, _ object: Any?,
                     _ handler: @escaping @MainActor (String?) -> Void) {
            observers.append(center.addObserver(forName: name, object: object,
                                                queue: .main) { note in
                let key = note.userInfo?["key"] as? String
                MainActor.assumeIsolated { handler(key) }
            })
        }
        observe(NSText.didChangeNotification, editor) { [weak self] _ in
            self?.editorTextDidChange()
        }
        // Highlighting changes fonts, and so the layout, without changing
        // the text. Posted synchronously, while `editedMask` is valid.
        observers.append(center.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: nil) { [weak self] note in
            let attributesOnly = (note.object as? NSTextStorage)
                .map { !$0.editedMask.contains(.editedCharacters) } ?? false
            MainActor.assumeIsolated {
                self?.editorStorageDidProcessEditing(attributesOnly: attributesOnly)
            }
        })
        // Only the preferences this controller reads, not other instances
        // (such as ones made for other user defaults suites).
        observe(.preferencesDidChange, preferences) { [weak self] key in
            self?.preferenceDidChange(key)
        }
        observe(.didRequestEditorSetup, nil) { [weak self] key in
            self?.setupEditor(key)
        }
        observe(.didRequestPreviewRender, nil) { [weak self] _ in
            self?.render()
        }
        let clipView = editorScrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, clipView) { [weak self] _ in
            self?.editorBoundsDidChange()
        }
        observe(NSScrollView.willStartLiveScrollNotification, editorScrollView) {
            [weak self] _ in
            self?.updateEditorAnchors()
            self?.inLiveScroll = true
        }
        observe(NSScrollView.didEndLiveScrollNotification, editorScrollView) {
            [weak self] _ in
            self?.inLiveScroll = false
        }

        for (key, _) in Self.editorKeysToObserve {
            let kvo = KeyValueObserver(object: editor, keyPath: key) {
                [weak self] value in
                guard let self, self.highlighter.isActive else { return }
                UserDefaults.standard.set(value,
                                          forKey: Self.preferenceKey(forEditorKey: key))
            }
            keyObservers.append(kvo)
        }
    }

    @ObservationIgnored private var keyObservers: [KeyValueObserver] = []
    /// The document's text as last saved (or loaded); see "Draft".
    @ObservationIgnored private(set) var savedText: String
    @ObservationIgnored private weak var attachedWindow: NSWindow?
    @ObservationIgnored private(set) var closeGuard: WindowCloseGuard?
    @ObservationIgnored private(set) var responder: DocumentResponder?
    /// Saves the document after the draft was copied into it, and reports
    /// whether it was saved. Replaceable for tests; the app saves through the
    /// window's NSDocument.
    @ObservationIgnored var saveDocument: ((DocumentController, @escaping (Bool) -> Void) -> Void)?
    /// Saves the document to a new file (after the draft was copied into it)
    /// and reports whether it was saved. Replaceable for tests; the app runs
    /// NSDocument's Save As panel.
    @ObservationIgnored var saveDocumentAs: ((DocumentController, @escaping (Bool) -> Void) -> Void)?
    /// Makes a copy of the document (with the draft copied into it).
    /// Replaceable for tests; the app uses NSDocument's duplicate().
    @ObservationIgnored var duplicateDocument: ((DocumentController) throws -> Void)?

    // MARK: - Accessors

    /// The editor's text (the draft). Setting it is an edit.
    public var markdown: String {
        get { editor.string }
        set {
            editor.string = newValue
            draftDidChange()
            highlighter.parseAndHighlightNow()
            parseAndRender()
        }
    }

    public var html: String { renderer.currentHTML }

    var needsHtml: Bool {
        if preferences.markdownManualRender { return false }
        return previewVisible || preferences.editorShowWordCount
    }

    var htmlTitle: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    var baseURL: URL? {
        fileURL ?? preferences.htmlDefaultDirectoryUrl
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    var window: NSWindow? { editor.window ?? preview.webView.window }

    // MARK: - Draft
    //
    // The editor edits a draft: its text. With "Save changes automatically"
    // on, every edit is copied into the document and the document is marked
    // changed, so AppKit autosaves it. Off, the document keeps the saved text
    // until the draft is saved, so neither AppKit nor SwiftUI sees changes to
    // save; the editor records undo on the controller's own undo manager for
    // the same reason. Unsaved changes are the draft differing from
    // `savedText`, which the window's edited dot, the Save button, closing
    // (WindowCloseGuard) and quitting (DocumentSaving) follow.

    private var autosaves: Bool { preferences.autosavesDocuments }

    /// The window's NSDocument (SwiftUI's), through public AppKit API.
    private var platformDocument: NSDocument? {
        window.flatMap { NSDocumentController.shared.document(for: $0) }
    }

    /// The name shown when asking about unsaved changes.
    var displayName: String {
        platformDocument?.displayName ?? fileURL?.lastPathComponent
            ?? String(localized: "Untitled")
    }

    /// Called after every change to the editor's text.
    private func draftDidChange() {
        if autosaves {
            commitDraft()
            platformDocument?.updateChangeCount(.changeDone)
        }
        updateUnsavedState()
    }

    /// Copies the draft into the document.
    private func commitDraft() {
        document.text = editor.string
        savedText = editor.string
    }

    private func updateUnsavedState() {
        // An untitled document with any text (typed, duplicated or piped in)
        // has never been saved anywhere.
        let untitledWithText = fileURL == nil && !editor.string.isEmpty
        let unsaved = !autosaves && (editor.string != savedText || untitledWithText)
        if unsaved != hasUnsavedChanges { hasUnsavedChanges = unsaved }
        if !autosaves, let window, window.isDocumentEdited != unsaved {
            window.isDocumentEdited = unsaved
        }
    }

    /// Saves the draft, like File ▸ Save (a save panel if it's untitled),
    /// and reports whether it was saved.
    public func save(completion: ((Bool) -> Void)? = nil) {
        let text = editor.string
        document.text = text
        let finish: (Bool) -> Void = { [weak self] saved in
            if saved, let self {
                self.savedText = text
                self.updateUnsavedState()
            }
            completion?(saved)
        }
        if let saveDocument {
            saveDocument(self, finish)
        } else if let platformDocument {
            // Tell AppKit the document changed so it writes the new text.
            platformDocument.updateChangeCount(.changeDone)
            DocumentSaveCallback.save(platformDocument, completion: finish)
        } else {
            finish(false)
        }
    }

    /// Saves the draft to a new file, like File ▸ Save As…, and reports
    /// whether it was saved. The window then edits the new file; the original
    /// file is left as it was last saved.
    public func saveAs(completion: ((Bool) -> Void)? = nil) {
        let text = editor.string
        // Into the document for writing, but without marking it changed:
        // AppKit would autosave the draft into the original file.
        document.text = text
        let finish: (Bool) -> Void = { [weak self] saved in
            guard let self else { return }
            if saved {
                self.savedText = text
            } else {
                // Cancelled: the document keeps holding what's on disk.
                self.document.text = self.savedText
            }
            self.updateUnsavedState()
            completion?(saved)
        }
        if let saveDocumentAs {
            saveDocumentAs(self, finish)
        } else if let platformDocument {
            DocumentSaveCallback.saveAs(platformDocument, completion: finish)
        } else {
            finish(false)
        }
    }

    /// Opens a copy of the document with the draft in it, like
    /// File ▸ Duplicate. This window keeps its draft and file as they were.
    public func duplicate() {
        document.text = editor.string
        defer { document.text = savedText }
        do {
            if let duplicateDocument {
                try duplicateDocument(self)
            } else if let platformDocument {
                _ = try platformDocument.duplicate()
            }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    /// Drops the draft's unsaved changes (when closing or quitting).
    func discardDraft() {
        savedText = editor.string
        updateUnsavedState()
    }

    /// Connects to the window once the views are in it: the close guard, the
    /// responder that handles File ▸ Save, and the edited dot.
    func attachToWindow() {
        guard let window, window !== attachedWindow else { return }
        closeGuard?.uninstall(from: attachedWindow)
        responder?.uninstall()
        attachedWindow = window
        let responder = DocumentResponder(controller: self)
        responder.install(in: window)
        self.responder = responder
        // With nothing focused, ⌘S would start at the window and reach the
        // document before the responder.
        if window.firstResponder === window, editorVisible {
            window.makeFirstResponder(editor)
        }
        let closeGuard = WindowCloseGuard(shouldClose: { _ in true })
        closeGuard.shouldClose = { [weak self, unowned closeGuard] window in
            guard let self else { return true }
            return DocumentSaving.windowShouldClose(window, controller: self,
                                                    closeGuard: closeGuard)
        }
        closeGuard.install(on: window)
        self.closeGuard = closeGuard
        updateUnsavedState()
    }

    // MARK: - Open controllers

    private static var openControllers: [WeakController] = []

    /// Document windows that are open, for asking about unsaved changes when
    /// quitting.
    static var allOpen: [DocumentController] {
        openControllers.compactMap(\.controller)
    }

    private static func register(_ controller: DocumentController) {
        openControllers.removeAll { $0.controller == nil }
        openControllers.append(WeakController(controller: controller))
    }

    private static func unregister(_ controller: DocumentController) {
        openControllers.removeAll { $0.controller == nil || $0.controller === controller }
    }

    private struct WeakController {
        weak var controller: DocumentController?
    }

    // MARK: - Rendering

    private func parseAndRender() {
        renderer.parse(editor.string, settings: preferences.renderSettings.parse) {
            [weak self] in
            self?.render()
        }
    }

    private func parseAndRenderNow() {
        renderer.parseNow(editor.string, settings: preferences.renderSettings.parse)
        render()
    }

    /// Renders the latest parse result into the preview.
    public func render() {
        // The new page loads at the top. The editor already matches the
        // preview, so let the preview follow it back to the same place.
        scrollLeader = .editor
        if preview.isLoading {
            renderPending = true
            return
        }
        // Delayed copying for copyHtml().
        if copying {
            copying = false
            writeHTMLToPasteboard()
        }
        let settings = preferences.renderSettings.page
        manualRender = preferences.markdownManualRender
        let html = PageBuilder.previewHTML(
            title: htmlTitle, result: renderer.result, settings: settings,
            linkTransform: PreviewURL.previewURL(for:))
        preview.load(html: html, baseURL: baseURL, waitForMathJax: settings.mathJax,
                     restoresScroll: !preferences.editorSyncScrolling)
        renderer.markRendered(with: settings)
    }

    private func previewDidFinishLoading() {
        attachToWindow()
        // A reloaded page is back at the top, wherever it was sent before.
        previewScrollTarget = nil
        scaleWebView()
        Task { [weak self] in
            guard let self else { return }
            if self.preferences.editorSyncScrolling {
                self.previewMetrics = await self.preview.fetchMetrics()
                self.updateEditorAnchors()
                self.syncScrollers()
            } else {
                self.preview.restoreScrollPosition()
            }
            if self.preferences.editorShowWordCount {
                await self.updateWordCount()
            }
            if let color = await self.preview.fetchBackgroundColor(),
               color.alphaComponent > 0 {
                self.previewBackgroundColor = color
            } else {
                // A transparent page shows the web view's white background.
                self.previewBackgroundColor = .white
            }
            if !self.editorVisible {
                self.dividerColor = self.previewBackgroundColor
            }
            #if DEBUG
            if DebugReport.directory != nil {
                // Give highlighting scripts and images a moment to finish.
                try? await Task.sleep(for: .seconds(1.5))
                await DebugReport.write(for: self)
            }
            #endif
        }
        if renderPending {
            renderPending = false
            render()
        }
    }

    private func updateWordCount() async {
        textCount = await preview.fetchTextCount()
        if preview.isReady { isTextCountReady = true }
    }

    private func scaleWebView() {
        guard preferences.previewZoomRelativeToBaseFontSize else {
            preview.webView.pageZoom = 1
            return
        }
        let fontSize = preferences.editorBaseFontSize
        guard fontSize > 0 else { return }
        preview.webView.pageZoom = fontSize / 14.0
    }

    // MARK: - Notification handlers

    private func editorTextDidChange() {
        draftDidChange()
        scrollLeader = .editor
        if needsHtml { parseAndRender() }
    }

    private func preferenceDidChange(_ key: String?) {
        if key == Preferences.autosavesDocumentsKey || key == nil {
            // Turning autosaving on saves the draft from then on.
            if autosaves && editor.string != savedText {
                commitDraft()
                platformDocument?.updateChangeCount(.changeDone)
            }
            updateUnsavedState()
        }
        if let key, Self.editorPreferencesToObserve.contains(key) {
            if highlighter.isActive { setupEditor(key) }
            redrawDivider()
        }
        if key == "editorShowWordCount" || key == nil {
            showsWordCount = preferences.editorShowWordCount
        }

        // Force update if switching from manual to auto, or parse settings
        // changed; otherwise re-render if page settings changed.
        let settings = preferences.renderSettings
        if (!preferences.markdownManualRender && manualRender)
            || settings.parse != renderer.lastParseSettings {
            if needsHtml || renderer.lastParseSettings != nil {
                parseAndRender()
            }
        } else if settings.page != renderer.lastPageSettings {
            render()
        }
    }

    private func editorBoundsDidChange() {
        guard shouldHandleBoundsChange, preferences.editorSyncScrolling else { return }
        shouldHandleBoundsChange = false
        scrollLeader = .editor
        if !inLiveScroll { updateEditorAnchors() }
        syncScrollers()
        shouldHandleBoundsChange = true
    }

    // MARK: - Editor setup

    public func setupEditor(_ changedKey: String?) {
        editorAnchorsKey = nil    // Fonts and insets move the text.
        highlighter.deactivate()

        if changedKey == nil || changedKey == "extensionFootnotes" {
            highlighter.extensions = preferences.extensionFootnotes
                ? Int32(pmh_EXT_NONE.rawValue) : Int32(pmh_EXT_NOTES.rawValue)
        }

        if changedKey == nil || ["editorHorizontalInset", "editorVerticalInset",
                                 "editorWidthLimited", "editorMaximumWidth"]
            .contains(changedKey!) {
            adjustEditorInsets()
        }

        if changedKey == nil || ["editorBaseFontInfo", "editorStyleName",
                                 "editorLineSpacing"].contains(changedKey!) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = preferences.editorLineSpacing
            editor.defaultParagraphStyle = style
            if let font = preferences.editorBaseFont {
                editor.font = font
            }
            editor.textColor = nil
            editor.backgroundColor = .textBackgroundColor
            editor.insertionPointColor = .textColor
            highlighter.resetStyles()
            highlighter.readClearTextStylesFromTextView()
            // Apply the font and paragraph style to existing text.
            if let storage = editor.textStorage, storage.length > 0 {
                let all = NSRange(location: 0, length: storage.length)
                storage.addAttribute(.paragraphStyle, value: style, range: all)
                if let font = editor.font {
                    storage.addAttribute(.font, value: font, range: all)
                }
            }

            if let themeName = preferences.editorStyleName, !themeName.isEmpty {
                let path = MPPaths.themePath(forName: themeName)
                let themeString = MPPaths.readFile(at: path)
                let errors = highlighter.applyStyles(fromStylesheet: themeString)
                if !errors.isEmpty {
                    NSLog("Errors in editor theme %@: %@", themeName,
                          errors.joined(separator: "; "))
                    preferences.editorStyleName = nil
                }
            }
            editorBackgroundColor = editor.backgroundColor
            editorScrollView.backgroundColor = editor.backgroundColor
        }

        if changedKey == "editorBaseFontInfo" {
            scaleWebView()
        }

        if changedKey == nil || changedKey == "editorShowWordCount" {
            showsWordCount = preferences.editorShowWordCount
            if showsWordCount {
                Task { await updateWordCount() }
            }
        }

        if changedKey == nil || changedKey == "editorScrollsPastEnd" {
            editor.scrollsPastEnd = preferences.editorScrollsPastEnd
        }

        if changedKey == nil {
            let defaults = UserDefaults.standard
            for (key, defaultValue) in Self.editorKeysToObserve {
                let value = defaults.object(forKey: Self.preferenceKey(forEditorKey: key))
                    ?? defaultValue
                editor.setValue(value, forKey: key)
            }
        }

        if changedKey == nil || changedKey == "editorOnRight" {
            let onRight = preferences.editorOnRight
            if onRight != editorOnRight {
                editorOnRight = onRight
            }
        }

        highlighter.activate()
        editor.isAutomaticLinkDetectionEnabled = false
    }

    func adjustEditorInsets() {
        var x = preferences.editorHorizontalInset
        let y = preferences.editorVerticalInset
        if preferences.editorWidthLimited {
            let editorWidth = editor.frame.size.width
            let maxWidth = preferences.editorMaximumWidth
            // We tend to expect things in an editor to shift to the left a
            // bit, hence 0.45 instead of 0.5.
            if editorWidth > 2 * x + maxWidth {
                x = (editorWidth - maxWidth) * 0.45
            }
        }
        editor.textContainerInset = NSSize(width: x, height: y)
    }

    func redrawDivider() {
        if !editorVisible {
            // Match the preview's background color.
            Task { dividerColor = await preview.fetchBackgroundColor() }
        } else if !previewVisible {
            dividerColor = editor.backgroundColor
        } else {
            dividerColor = nil
        }
    }

    // MARK: - Split view

    /// Called when the user drags the divider.
    public func userDidResizeSplit(to fraction: CGFloat) {
        let wasVisible = previewVisible
        editorFraction = min(max(fraction, 0), 1)
        splitDidChange(previewWasVisible: wasVisible)
    }

    private func setEditorFraction(_ fraction: CGFloat) {
        let wasVisible = previewVisible
        editorFraction = fraction
        splitDidChange(previewWasVisible: wasVisible)
    }

    private func splitDidChange(previewWasVisible: Bool) {
        editor.isEditable = editorVisible
        if !previewWasVisible && previewVisible && !preferences.markdownManualRender {
            parseAndRenderNow()
        }
        DispatchQueue.main.async { [weak self] in
            self?.adjustEditorInsets()
        }
        redrawDivider()
    }

    /// Sets the left pane's share of the window, like the original menu
    /// items ("Left 1:3 Right" etc.).
    public func setLeftPaneFraction(_ ratio: CGFloat) {
        setEditorFraction(editorOnRight ? 1 - ratio : ratio)
    }

    public func togglePreviewPane() { toggleSplitter(collapsingEditor: false) }
    public func toggleEditorPane() { toggleSplitter(collapsingEditor: true) }

    private func toggleSplitter(collapsingEditor: Bool) {
        let isVisible = collapsingEditor ? editorVisible : previewVisible
        if isVisible {
            let old = editorFraction
            // Don't save meaningless values, so the user can switch between
            // 100% editor and 100% preview without losing the old ratio.
            if old > 0.001 && old < 0.999 {
                previousEditorFraction = old
            }
            setEditorFraction(collapsingEditor ? 0 : 1)
        } else {
            if previousEditorFraction < 0 { previousEditorFraction = 0.5 }
            setEditorFraction(previousEditorFraction)
        }
    }

    // MARK: - Scroll synchronization

    enum ScrollLeader { case editor, preview }

    private var editorGeometry: ScrollGeometry {
        ScrollGeometry(
            contentHeight: editorScrollView.documentView?.bounds.height ?? 0,
            visibleHeight: editorScrollView.contentView.bounds.height)
    }

    private var scrollMap: ScrollMap {
        ScrollMap(editor: editorAnchors, preview: previewMetrics.anchors,
                  editorEnd: editorTextEnd, previewEnd: previewMetrics.contentHeight)
    }

    /// Finds the editor's scroll anchors and where they are laid out.
    func updateEditorAnchors() {
        guard let layoutManager = editor.layoutManager,
              let container = editor.textContainer
        else { return }
        let key = (text: editor.string, width: container.size.width,
                   frontMatter: preferences.htmlDetectFrontMatter,
                   fencedCode: preferences.extensionFencedCode)
        if let old = editorAnchorsKey, old == key { return }
        editorAnchorsKey = key
        let origin = editor.textContainerOrigin.y
        layoutManager.ensureLayout(for: container)
        let sourceAnchors = ScrollAnchors.scan(key.text, skipsFrontMatter: key.frontMatter,
                                               fencedCode: key.fencedCode)
        editorAnchors = sourceAnchors.map { anchor in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: anchor.range,
                                                      actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            return ScrollAnchor(anchor.kind, origin + rect.midY)
        }
        editorTextEnd = origin + layoutManager.usedRect(for: container).maxY
    }

    /// Scrolls the pane that isn't being scrolled by the user to match the
    /// one that is.
    private func syncScrollers() {
        guard preferences.editorSyncScrolling,
              previewMetrics.visibleHeight > 0, editorGeometry.visibleHeight > 0
        else { return }
        switch scrollLeader {
        case .editor:
            let y = scrollMap.previewOffset(
                forEditorOffset: editorScrollView.contentView.bounds.minY,
                editor: editorGeometry, preview: previewMetrics.geometry)
            // Re-syncing to the same place (e.g. after restyling) mustn't
            // restart the window in which preview scrolling is ignored.
            if let target = previewScrollTarget, abs(target.y - y) < 1 {
                return
            }
            previewScrollTarget = (y, Date())
            preview.scroll(to: y)
        case .preview:
            let y = scrollMap.editorOffset(
                forPreviewOffset: preview.lastScrollTop,
                editor: editorGeometry, preview: previewMetrics.geometry)
            let clipView = editorScrollView.contentView
            let handled = shouldHandleBoundsChange
            shouldHandleBoundsChange = false
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: y))
            editorScrollView.reflectScrolledClipView(clipView)
            shouldHandleBoundsChange = handled
        }
    }

    private func previewDidScroll(to y: CGFloat) {
        guard preferences.editorSyncScrolling else { return }
        // Ignore scrolling caused by syncScrollers().
        if let target = previewScrollTarget,
           abs(target.y - y) < 1 || Date().timeIntervalSince(target.date) < 0.25 {
            return
        }
        previewScrollTarget = nil
        scrollLeader = .preview
        syncScrollers()
    }

    /// The preview was resized, or images finished loading.
    private func previewLayoutDidChange() {
        guard preferences.editorSyncScrolling else { return }
        Task { [weak self] in
            guard let self else { return }
            self.previewMetrics = await self.preview.fetchMetrics()
            self.updateEditorAnchors()
            self.syncScrollers()
        }
    }

    /// The editor's text or its styles changed.
    private func editorStorageDidProcessEditing(attributesOnly: Bool) {
        editorAnchorsKey = nil
        // Text edits re-render, which syncs. Restyling alone moves the
        // editor's text, so the preview has to follow.
        guard attributesOnly, !inLiveScroll, !editorLayoutSyncScheduled,
              preferences.editorSyncScrolling, isSetUp
        else { return }
        editorLayoutSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorLayoutSyncScheduled = false
            guard !self.preview.isLoading else { return }
            self.updateEditorAnchors()
            self.syncScrollers()
        }
    }

    /// The editor's width changed, so its text wrapped differently.
    private func editorLayoutDidChange() {
        guard preferences.editorSyncScrolling, isSetUp else { return }
        DispatchQueue.main.async { [weak self] in
            self?.updateEditorAnchors()
            self?.syncScrollers()
        }
    }

    // MARK: - Actions

    public func copyHtml() {
        // If the preview is hidden, the HTML is not updating on text change.
        if !needsHtml {
            renderer.parseNow(editor.string, settings: preferences.renderSettings.parse)
        }
        writeHTMLToPasteboard()
    }

    private func writeHTMLToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([renderer.currentHTML as NSString])
    }

    public func renderNow() {
        parseAndRender()
    }

    public func convertToHeader(level: Int) {
        editor.makeHeaderForSelectedLines(level: level)
    }

    public func toggleStrong() { editor.toggleForMarkup(prefix: "**", suffix: "**") }
    public func toggleEmphasis() { editor.toggleForMarkup(prefix: "*", suffix: "*") }
    public func toggleInlineCode() { editor.toggleForMarkup(prefix: "`", suffix: "`") }
    public func toggleStrikethrough() { editor.toggleForMarkup(prefix: "~~", suffix: "~~") }
    public func toggleUnderline() { editor.toggleForMarkup(prefix: "_", suffix: "_") }
    public func toggleHighlight() { editor.toggleForMarkup(prefix: "==", suffix: "==") }
    public func toggleComment() { editor.toggleForMarkup(prefix: "<!--", suffix: "-->") }

    public func toggleLink() { toggleLinkLike(prefix: "[") }
    public func toggleImage() { toggleLinkLike(prefix: "![") }

    private func toggleLinkLike(prefix: String) {
        guard editor.toggleForMarkup(prefix: prefix, suffix: "]()") else { return }
        var range = editor.selectedRange()
        range = NSRange(location: range.location + range.length + 2, length: 0)

        if let string = NSPasteboard.general.string(forType: .string),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            let text = url.absoluteString
            editor.insertText(text, replacementRange: range)
            range.length = (text as NSString).length
        }
        editor.setSelectedRange(range)
    }

    public func toggleOrderedList() {
        editor.toggleBlock(pattern: "^[0-9]+ \\S", prefix: "1. ")
    }

    public func toggleUnorderedList() {
        editor.toggleBlock(pattern: "^[\\*\\+-] \\S",
                           prefix: preferences.editorUnorderedListMarker)
    }

    public func toggleBlockquote() {
        editor.toggleBlock(pattern: "^> \\S", prefix: "> ")
    }

    public func indent() {
        editor.indentSelectedLines(padding: preferences.editorConvertTabs ? "    " : "\t")
    }

    public func unindent() {
        editor.unindentSelectedLines()
    }

    public func insertNewParagraph() {
        let range = editor.selectedRange()
        let content = editor.string as NSString
        let newlineBefore = content.locationOfFirstNewline(before: range.location)
        let newlineAfter = content.locationOfFirstNewline(
            after: range.location + range.length - 1)
        // On an empty line, treat as a normal return; otherwise insert two
        // newlines.
        if range.location == newlineBefore + 1 && range.location == newlineAfter {
            editor.insertNewline(nil)
        } else {
            editor.insertText("\n\n", replacementRange: editor.selectedRange())
        }
    }

    // MARK: - Export & print

    /// A file name derived from the document, for save panels.
    public var presumedFileName: String {
        if let fileURL {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        let string = editor.string
        if preferences.htmlDetectFrontMatter,
           let title = string.frontMatter().object?["title"]?.stringValue {
            return title
        }
        guard let title = string.titleString else {
            return String(localized: "Untitled")
        }
        return title.replacingOccurrences(of: "[/|:]", with: "-",
                                          options: .regularExpression)
    }

    public func exportHtml() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = presumedFileName
        let accessory = ExportAccessoryView(
            stylesIncluded: preferences.htmlStyleName != nil,
            highlightingIncluded: preferences.htmlSyntaxHighlighting)
        panel.accessoryView = accessory

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if !self.needsHtml {
                self.renderer.parseNow(self.editor.string,
                                       settings: self.preferences.renderSettings.parse)
            }
            let html = PageBuilder.exportHTML(
                title: self.htmlTitle, result: self.renderer.result,
                settings: self.preferences.renderSettings.page,
                withStyles: accessory.stylesIncluded,
                withHighlighting: accessory.highlightingIncluded)
            do {
                try html.write(to: url, atomically: false, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    public func exportPdf() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = presumedFileName
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let info = self.printInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = self.preview.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            self.run(operation)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    public func printDocument() {
        let operation = preview.printOperation(with: printInfo())
        operation.showsPrintPanel = true
        run(operation)
    }

    private func run(_ operation: NSPrintOperation) {
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 50
        info.leftMargin = 0
        info.rightMargin = 0
        info.bottomMargin = 50
        return info
    }

    // MARK: - Links

    func openOrCreateFile(for url: URL) {
        var url = url
        let isFile = url.isFileURL
        var reachable = !isFile || ((try? url.checkResourceIsReachable()) ?? false)

        // If the local file doesn't exist, check for a file with ".md".
        if isFile && !reachable && url.pathExtension.isEmpty {
            let markdownURL = url.appendingPathExtension("md")
            if (try? markdownURL.checkResourceIsReachable()) ?? false {
                reachable = true
                url = markdownURL
            }
        }

        if reachable {
            open(url)
            return
        }

        // Show an error if the user doesn't want us to create it.
        if !preferences.createFileForLinkTarget {
            let alert = NSAlert()
            alert.messageText = String(format: String(localized:
                "File not found at path:\n%@"), url.path)
            alert.informativeText = String(localized: """
                Please check the path of your link is correct. Turn on \
                “Automatically create link targets” If you want MacDown to \
                create nonexistent link targets for you.
                """)
            alert.runModal()
            return
        }

        // We can only create a file if the current file is saved.
        if fileURL == nil {
            let alert = NSAlert()
            alert.messageText = String(format: String(localized:
                "Can’t create file:\n%@"), url.lastPathComponent)
            alert.informativeText = String(localized: """
                MacDown can’t create a file for the clicked link because the \
                current file is not saved anywhere yet. Save the current file \
                somewhere to enable this feature.
                """)
            alert.runModal()
            return
        }

        do {
            try Data().write(to: url, options: .withoutOverwriting)
            open(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(format: String(localized:
                "Can’t create file:\n%@"), url.lastPathComponent)
            alert.informativeText = String(format: String(localized:
                "An error occurred while creating the file:\n%@"),
                error.localizedDescription)
            alert.runModal()
        }
    }

    private func open(_ url: URL) {
        if url.isFileURL, let type = UTType(filenameExtension: url.pathExtension),
           MarkdownDocument.readableContentTypes.contains(where: type.conforms(to:)) {
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true) { _, _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Word count

    public func wordCountTitle(for type: WordCountType) -> String {
        func plural(_ key: String, _ value: Int) -> String {
            // The app's string catalog has the translations; the package's
            // English table is the fallback (e.g. in tests).
            var format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
            if format == key {
                format = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
            }
            let forms = format.components(separatedBy: ";")
            let form = forms.count > 1 ? (value == 1 ? forms[0] : forms[1]) : forms[0]
            return form.replacingOccurrences(of: "%@", with: "\(value)")
        }
        switch type {
        case .words:
            return plural("WORDS_PLURAL_STRING", textCount.words)
        case .characters:
            return plural("CHARACTERS_PLURAL_STRING", textCount.characters)
        case .charactersNoSpaces:
            return plural("CHARACTERS_NO_SPACES_PLURAL_STRING",
                          textCount.charactersNoSpaces)
        }
    }
}

// MARK: - NSTextViewDelegate

extension DocumentController: NSTextViewDelegate {
    public func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            return !textViewShouldInsertTab(textView)
        case #selector(NSResponder.insertBacktab(_:)):
            unindent()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return !textViewShouldInsertNewline(textView)
        case #selector(NSResponder.deleteBackward(_:)):
            return !textViewShouldDeleteBackward(textView)
        case #selector(NSResponder.moveToLeftEndOfLine(_:)):
            return !textViewShouldMoveToLeftEndOfLine(textView)
        default:
            return false
        }
    }

    public func textView(_ textView: NSTextView,
                         shouldChangeTextIn range: NSRange,
                         replacementString string: String?) -> Bool {
        // Ignore if this originates from an IM marked text commit event.
        if NSIntersectionRange(textView.markedRange(), range).length > 0 {
            return true
        }
        guard let string else { return true }
        if preferences.editorCompleteMatchingCharacters {
            if textView.completeMatchingCharacters(
                forTextIn: range, with: string,
                strikethroughEnabled: preferences.extensionStrikethough) {
                return false
            }
        }
        return true
    }

    private func textViewShouldInsertTab(_ textView: NSTextView) -> Bool {
        if textView.selectedRange().length != 0 {
            indent()
            return false
        } else if preferences.editorConvertTabs {
            textView.insertSpacesForTab()
            return false
        }
        return true
    }

    private func textViewShouldInsertNewline(_ textView: NSTextView) -> Bool {
        let inserts = preferences.editorInsertPrefixInBlock
        if inserts && textView.completeNextListItem(
            autoIncrement: preferences.editorAutoIncrementNumberedLists) {
            return false
        }
        if inserts && textView.completeNextBlockquoteLine() {
            return false
        }
        if textView.completeNextIndentedLine() {
            return false
        }
        return true
    }

    private func textViewShouldDeleteBackward(_ textView: NSTextView) -> Bool {
        let selected = textView.selectedRange()
        if preferences.editorCompleteMatchingCharacters && selected.length == 0,
           textView.deleteMatchingCharacters(around: selected.location) {
            return false
        }
        if preferences.editorConvertTabs && selected.length == 0,
           textView.unindentForSpaces(before: selected.location) {
            return false
        }
        return true
    }

    private func textViewShouldMoveToLeftEndOfLine(_ textView: NSTextView) -> Bool {
        guard preferences.editorSmartHome else { return true }
        let content = textView.string as NSString
        var cur = textView.selectedRange().location
        let location = content.locationOfFirstNonWhitespaceCharacterInLine(before: cur)
        if location == cur || cur == 0 { return true }
        if cur >= content.length { cur = content.length - 1 }

        // Don't jump rows when the line is wrapped.
        guard let manager = textView.layoutManager,
              let container = textView.textContainer
        else { return true }
        let targetRect = manager.boundingRect(
            forGlyphRange: NSRange(location: location, length: 1), in: container)
        let currentRect = manager.boundingRect(
            forGlyphRange: NSRange(location: cur, length: 1), in: container)
        if targetRect.origin.y != currentRect.origin.y { return true }

        textView.setSelectedRange(NSRange(location: location, length: 0))
        return false
    }
}

/// Key-value observation by string key path.
final class KeyValueObserver: NSObject {
    private weak var object: NSObject?
    private let keyPath: String
    private let handler: @MainActor (Any?) -> Void

    init(object: NSObject, keyPath: String,
         handler: @escaping @MainActor (Any?) -> Void) {
        self.object = object
        self.keyPath = keyPath
        self.handler = handler
        super.init()
        object.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
    }

    deinit {
        object?.removeObserver(self, forKeyPath: keyPath)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        nonisolated(unsafe) let value = change?[.newKey]
        let handler = self.handler
        MainActor.assumeIsolated {
            handler(value)
        }
    }
}

/// Accessory view of the HTML export panel.
final class ExportAccessoryView: NSView {
    private let stylesButton: NSButton
    private let highlightingButton: NSButton

    var stylesIncluded: Bool { stylesButton.state == .on }
    var highlightingIncluded: Bool { highlightingButton.state == .on }

    init(stylesIncluded: Bool, highlightingIncluded: Bool) {
        stylesButton = NSButton(checkboxWithTitle: String(localized: "Include styles"),
                                target: nil, action: nil)
        highlightingButton = NSButton(
            checkboxWithTitle: String(localized: "Include syntax highlighting"),
            target: nil, action: nil)
        stylesButton.state = stylesIncluded ? .on : .off
        highlightingButton.state = highlightingIncluded ? .on : .off
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 44))

        let stack = NSStackView(views: [stylesButton, highlightingButton])
        stack.orientation = .horizontal
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

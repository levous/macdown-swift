# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Swift 6 / SwiftUI port of MacDown (the Objective-C Markdown editor for macOS). The port keeps the original's behavior and user defaults keys; Markdown follows CommonMark and GitHub Flavored Markdown (cmark-gfm), with the original's HTML markup (classes, code blocks, footnotes) so its styles and scripts still apply. When changing behavior, check whether it diverges from the original MacDown; intentional differences are listed in docs/MACDOWN-PORT.md ("Differences from the original"). Many files say which Objective-C file they were ported from (e.g. `Ported from MPRenderer.m`), and docs/MACDOWN-PORT.md has a table mapping the original classes onto the port.

Documentation: README.md welcomes users (what MacDown is, how to install it, what it does) and doesn't discuss the port. docs/ARCHITECTURE.md has the technical detail (layout, pipelines, development workflow) and a dated "Decisions" log. docs/MACDOWN-PORT.md has everything about the relationship to the original MacDown (what carries over, differences, class map, port decisions).

## Commands

Requires macOS 15+, Xcode 27 (Swift 6.4 toolchain), and XcodeGen for the app.

```sh
swift build                                   # C libs, MacDownKit, macdown CLI
swift test                                    # Swift Testing suite
swift test --filter AutocompleteTests         # one suite
swift test --filter "AutocompleteTests/toggleStrong"   # one test

xcodegen generate                             # regenerate MacDown.xcodeproj from project.yml (the project is gitignored)
xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Debug build
```

Releases: `Tools/release.sh <version> [--dry-run]` (see docs/ARCHITECTURE.md, "Releasing"). The version lives in both `project.yml` and `MacDownShared/Globals.swift`; the script keeps them in sync.

There is no linter configured.

## Build structure

- `Package.swift` (SwiftPM) holds everything except the app's `@main`: the C targets `CHoedown` and `CPegMarkdown`, `MacDownShared`, `MacDownKit`, the `macdown-cmd` executable, and the tests. Almost all code lives in `MacDownKit`. `App/MacDownApp.swift` only wires `MacDownScene` and `MacDownAppDelegate`.
- `project.yml` (XcodeGen) defines the `MacDown` app target, which depends on the local package, and embeds the `macdown` tool in `Contents/SharedSupport/bin`. Edit `project.yml`, not the generated `.xcodeproj`.
- Resources load through `MPPaths.resourceBundle` (`Bundle.module`). New resource directories must be added to the `resources:` list in `Package.swift`.
- Strict concurrency is on (`swiftLanguageModes: [.v6]`, `SWIFT_STRICT_CONCURRENCY: complete`). UI types are `@MainActor`, and parsing runs off the main actor.

## Render pipeline

1. `DocumentController` (one per window, the central `@MainActor` coordinator that owns the editor, preview, renderer and the formatting/export actions) observes editor text and preference changes.
2. `Preferences.renderSettings` turns preferences into `RenderSettings` = `ParseSettings` (Markdown options, stored as hoedown's flags, and the hidden `markdownEngine`) + `PageSettings` (styles, Prism, MathJax, Mermaid, Graphviz, template).
3. `Renderer.parse` builds a `MarkdownDocumentModel` in a detached task (a generation counter discards superseded parses). The model (`Document/Model`, the only code that calls cmark-gfm) protects math and front matter (`ProtectedSource`), parses once with cmark-gfm (`CMarkTree`), and walks the tree there: `HTMLRenderer` writes the preview body (hoedown's markup, Prism languages, `[TOC]`, front matter table, math for MathJax, `data-source-line` for scroll sync) and `HighlightMapper` the editor's highlight spans and blocks. Only `Sendable` results leave the task. With `markdownEngine = hoedown` (selectable for one release, then removed) `MarkdownParser` renders with the original's patched hoedown instead.
4. `PageBuilder` (pure static functions) builds the full HTML page from the parse result using `HTMLTemplate` (a minimal Handlebars subset) and `Asset` (linked or embedded CSS/JS). The same builder makes the preview HTML and the HTML/PDF export, with different embedding options.
5. `PreviewController` loads the page into a `WKWebView`. File URLs are rewritten to `x-macdown-preview://local/<path>` (`PreviewURL` / `LocalFileSchemeHandler`) because WKWebView pages loaded from a string can't read local files. Metrics for scroll sync, word count and background color come back via JS evaluation and script message handlers. When a new page differs from the loaded one only between the `<!--macdown-body-start/end-->` markers (added by `previewHTML` only, not exports), `load` swaps the body in place and re-runs the page scripts instead of reloading; anything that changes styles, scripts or the base URL reloads the page.

The output keeps hoedown's markup where CommonMark agrees; `HTMLRendererTests` compare it with hoedown byte for byte, and every remaining difference over the test corpus is reviewed in `Tests/MacDownKitTests/Resources/reviewed-html-diffs.json` and summarized in docs/MACDOWN-PORT.md. Don't add C: renderer changes go in `HTMLRenderer`.

## Saving

The editor edits a draft (its text); `MarkdownDocument.text` is the persisted state. With "Save changes automatically" (`autosavesDocuments`) on, every edit is copied into the document and the window's NSDocument is told it changed (`updateChangeCount`), so AppKit autosaves. Off, the document only receives the draft on Save (`DocumentController.save`), and the editor records undo on the controller's own `UndoManager` rather than SwiftUI's, so SwiftUI/AppKit never see changes to autosave. Unsaved changes are the draft differing from `savedText`, or an untitled document with any text (a duplicate, piped-in text); Save As copies the draft into the document without marking it changed (that would autosave the draft into the original file) and restores the saved text if cancelled; the controller drives the window's edited dot and the toolbar Save button from that. File ▸ Save (⌘S, AppKit's `saveDocument:`), Save As… and Duplicate are handled by `DocumentResponder`, inserted in the responder chain just before the window (after SwiftUI's `AppKitWindowHostingController`): SwiftUI's window passes the action to the NSDocument as its supplemental target, which would save the stale document text. `tryToPerform` skips supplemental targets, so test the chain the way AppKit dispatches menu actions. Closing goes through `WindowCloseGuard` (a forwarding wrapper around SwiftUI's window delegate that answers `windowShouldClose`), quitting through the app delegate's `applicationShouldTerminate`; both ask via `DocumentSaving`. Answers are acted on after AppKit finishes the current close request (NSDocument won't save from inside it). `NSWindow.performClose` runs a nested event loop that ends a Swift Testing run early, so tests replace `WindowCloseGuard.closeWindow`.

## Editor

`EditorTextView` (an `NSTextView` subclass) is hosted in SwiftUI through `Representables`. The editing helpers (list/blockquote continuation, auto-pairing, toggling markup, indenting) are in `NSTextView+Autocomplete.swift` and are called from `DocumentController`'s `NSTextViewDelegate` methods. Syntax highlighting is `MarkdownHighlighter`, which styles the visible range from spans keyed by PEG Markdown Highlight's element types, so the original `.style` themes (parsed by `ThemeStyle`) apply. The spans come from the document model's `HighlightMapper` (handed over by `DocumentController` after each parse); with the hoedown engine, from the PEG C parser, whose `pmh_parser.c` is generated code (see docs/ARCHITECTURE.md). Don't hand-edit it.

## App ↔ shell utility

`macdown-cmd` and the app communicate only through the shared user defaults suite and keys in `MacDownShared/Globals.swift` (`filesToOpenOnNextLaunch`, `pipedContentFileToOpenOnNextLaunch`). Changing those keys, or the bundle identifier `io.github.levous.macdown-swift`, requires changing both sides. Preference keys are the cases of `PreferenceSettingKey` (`Preferences/PreferenceSettingKey.swift`); use them instead of strings (`defaults.bool(forKey: .editorConvertTabs)`, `Notification.preferenceKey`). Raw values must keep matching the original app's user defaults keys.

## Localization

UI strings use `String(localized:)` and go into `App/Localizable.xcstrings`. After adding UI strings, re-run `python3 Tools/import_localizations.py /path/to/original/macdown` to pull in the original translations. New strings fall back to English unless translated in `Tools/port_translations.json`, which the script merges in.

## Debugging rendered output

Debug builds write a JSON report of each preview render (Prism tokens, TOC links, images, stylesheets, word count, highlighting) and PNG snapshots when `MACDOWN_DEBUG_REPORT` is set to a directory:
`open -a MacDown.app --env MACDOWN_DEBUG_REPORT=/tmp/report file.md` (add `--env MACDOWN_DEBUG_EDIT=1` to also test edit/undo). See `Document/DebugReport.swift`.

## Tests

The bundled help (`Resources/help.md`) has a live example of every Markdown feature and setting, and `HelpDocumentTests` renders it, checks the editor highlighting over it, and loads it in the real preview (Prism, Mermaid, Graphviz, images, task lists). When you add or change a feature, update its section in `help.md` and the matching expectations. Live examples that need a setting use text distinct from the "Inline Formatting" table, which shows results as literal HTML.

The tests use Swift Testing (`@Suite`/`@Test`), not XCTest, which runs suites in parallel. Suites that drive a real `DocumentController` with a live WKWebView or change `Preferences.shared` (`DocumentControllerTests`, `ScrollSyncIntegrationTests`) are nested in the serialized `LiveDocumentTests` suite so they don't interfere; put new ones there too. WebKit doesn't run animation frames in the (off-screen) test windows, so the page's scroll and layout reports don't fire; tests call `PreviewController.pageDidScroll(to:)` / `pageLayoutDidChange()` instead. Test fixtures are in `Tests/MacDownKitTests/Resources`. The migration corpus (`Resources/Corpus`) is generated test Markdown; never add real user documents or other docs to it. `HTMLDiffHarnessTests` and `HighlightDiffHarnessTests` compare the engines over it and fail on any difference not reviewed (`Resources/reviewed-html-diffs.json`, `HighlightDiffHarnessTests.reviewed`, `Resources/expected-html-diffs.json`); `MACDOWN_DIFF_REPORT=<dir>` writes reports (see docs/ARCHITECTURE.md, "Tests"). Live tests that depend on the engine set `Preferences.shared.markdownEngine` themselves.

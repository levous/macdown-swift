# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Swift 6 / SwiftUI port of MacDown (the Objective-C Markdown editor for macOS). The port aims to keep the original's behavior, HTML output, and user defaults keys unchanged. When changing behavior, check whether it diverges from the original MacDown; intentional differences are listed in README.md ("Differences from the original"). Many files say which Objective-C file they were ported from (e.g. `Ported from MPRenderer.m`), and README.md has a table mapping the original classes onto the port.

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

There is no linter configured.

## Build structure

- `Package.swift` (SwiftPM) holds everything except the app's `@main`: the C targets `CHoedown` and `CPegMarkdown`, `MacDownShared`, `MacDownKit`, the `macdown-cmd` executable, and the tests. Almost all code lives in `MacDownKit`. `App/MacDownApp.swift` only wires `MacDownScene` and `MacDownAppDelegate`.
- `project.yml` (XcodeGen) defines the `MacDown` app target, which depends on the local package, and embeds the `macdown` tool in `Contents/SharedSupport/bin`. Edit `project.yml`, not the generated `.xcodeproj`.
- Resources load through `MPPaths.resourceBundle` (`Bundle.module`). New resource directories must be added to the `resources:` list in `Package.swift`.
- Strict concurrency is on (`swiftLanguageModes: [.v6]`, `SWIFT_STRICT_CONCURRENCY: complete`). UI types are `@MainActor`, and parsing runs off the main actor.

## Render pipeline

1. `DocumentController` (one per window, the central `@MainActor` coordinator that owns the editor, preview, renderer and the formatting/export actions) observes editor text and preference changes.
2. `Preferences.renderSettings` turns preferences into `RenderSettings` = `ParseSettings` (hoedown extension and renderer flags) + `PageSettings` (styles, Prism, MathJax, Mermaid, Graphviz, template).
3. `Renderer.parse` runs `MarkdownParser.parse` (a pure function that bridges hoedown through C callbacks) in a detached task. A generation counter discards results from superseded parses. The parser also handles Jekyll front matter (Yams, converted to an HTML table), `[TOC]` substitution, and collecting code block languages for Prism.
4. `PageBuilder` (pure static functions) builds the full HTML page from the parse result using `HTMLTemplate` (a minimal Handlebars subset) and `Asset` (linked or embedded CSS/JS). The same builder makes the preview HTML and the HTML/PDF export, with different embedding options.
5. `PreviewController` loads the page into a `WKWebView`. File URLs are rewritten to `x-macdown-preview://local/<path>` (`PreviewURL` / `LocalFileSchemeHandler`) because WKWebView pages loaded from a string can't read local files. Metrics for scroll sync, word count and background color come back via JS evaluation and script message handlers. When a new page differs from the loaded one only between the `<!--macdown-body-start/end-->` markers (added by `previewHTML` only, not exports), `load` swaps the body in place and re-runs the page scripts instead of reloading; anything that changes styles, scripts or the base URL reloads the page.

The HTML output has to stay identical to the original app. Renderer changes in C belong in `Sources/CHoedown/hoedown_html_patch.c` (task lists, code block info, Prism-compatible code blocks, TOC classes), not in upstream hoedown files.

## Editor

`EditorTextView` (an `NSTextView` subclass) is hosted in SwiftUI through `Representables`. The editing helpers (list/blockquote continuation, auto-pairing, toggling markup, indenting) are in `NSTextView+Autocomplete.swift` and are called from `DocumentController`'s `NSTextViewDelegate` methods. Syntax highlighting is `MarkdownHighlighter`, which drives the PEG Markdown Highlight C parser with the original `.style` themes. `pmh_parser.c` is generated code (see README "Regenerating the highlighter parser"). Don't hand-edit it.

## App ↔ shell utility

`macdown-cmd` and the app communicate only through the shared user defaults suite and keys in `MacDownShared/Globals.swift` (`filesToOpenOnNextLaunch`, `pipedContentFileToOpenOnNextLaunch`). Changing those keys, or the bundle identifier `io.github.levous.macdown-swift`, requires changing both sides. Preference keys in `Preferences.swift` must keep matching the original app's user defaults keys.

## Localization

UI strings use `String(localized:)` and go into `App/Localizable.xcstrings`. After adding UI strings, re-run `python3 Tools/import_localizations.py /path/to/original/macdown` to pull in the original translations. New strings fall back to English.

## Debugging rendered output

Debug builds write a JSON report of each preview render (Prism tokens, TOC links, images, stylesheets, word count, highlighting) and PNG snapshots when `MACDOWN_DEBUG_REPORT` is set to a directory:
`open -a MacDown.app --env MACDOWN_DEBUG_REPORT=/tmp/report file.md` (add `--env MACDOWN_DEBUG_EDIT=1` to also test edit/undo). See `Document/DebugReport.swift`.

## Tests

The tests use Swift Testing (`@Suite`/`@Test`), not XCTest. `DocumentControllerTests` is `.serialized` and drives a real `DocumentController` with a live WKWebView. Test fixtures are in `Tests/MacDownKitTests/Resources`.

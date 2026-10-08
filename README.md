# MacDown (Swift)

A port of [MacDown](https://github.com/MacDownApp/macdown), the open source
Markdown editor for macOS, from Objective-C/AppKit/WebView to **Swift 6** and
**SwiftUI**.

The port keeps MacDown's behavior, rendering output and preferences:

- Live preview, rendered with the same patched [hoedown](https://github.com/hoedown/hoedown)
  3.0.7 engine, so HTML output is identical to the original.
- Editor syntax highlighting with [PEG Markdown Highlight](http://hasseg.org/peg-markdown-highlight/)
  and the original `.style` editor themes.
- Prism syntax highlighting, MathJax, Mermaid, Graphviz, task lists, Jekyll
  front matter, `[TOC]`, smartypants, and all of hoedown's Markdown extensions.
- The editor helpers: list and blockquote continuation, auto-pairing of
  brackets and quotes, smart Home, tab/space conversion, toggling markup,
  headers, lists, links and images.
- Scroll synchronization between editor and preview, word count, HTML and
  PDF export, printing, customizable toolbar and the full Format/View menus
  with the original keyboard shortcuts.
- The `macdown` shell utility (open files from a terminal or pipe text in),
  the `x-macdown://open?url=…` URL scheme, and plug-ins.
- User defaults keys are unchanged, and styles and themes are read from the
  same `~/Library/Application Support/MacDown` folder.

## Requirements

- macOS 15 or later
- Xcode 27 or later (Swift 6.4 toolchain)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project

## Building

```sh
# Core library and tests (no Xcode project needed)
swift build
swift test

# The application
xcodegen generate
open MacDown.xcodeproj        # or:
xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Release build
```

The `macdown` shell utility is embedded in the app at
`MacDown.app/Contents/SharedSupport/bin/macdown`; install it from
Settings ▸ Terminal.

## Releasing

`Tools/release.sh <version>` bumps the version, builds and notarizes the app,
publishes a GitHub release and updates the `macdown-swift` cask in
[levous/homebrew-tap](https://github.com/levous/homebrew-tap):

```sh
Tools/release.sh 1.1 --dry-run   # build and check locally, publish nothing
Tools/release.sh 1.1
brew install --cask levous/tap/macdown-swift
```

Releases need a "Developer ID Application" certificate and notarization
credentials; see the top of the script.

## Layout

| Path | Contents |
|------|----------|
| `Package.swift` | Swift package with everything except the app entry point |
| `Sources/CHoedown` | hoedown 3.0.7 plus MacDown's renderer patches (`hoedown_html_patch.c`) |
| `Sources/CPegMarkdown` | PEG Markdown Highlight parser (C) |
| `Sources/MacDownShared` | Constants shared by the app and the shell utility |
| `Sources/MacDownKit/Document` | Markdown parsing, page assembly, the document model and per-window controller |
| `Sources/MacDownKit/Editor` | `NSTextView` subclass, editing helpers, syntax highlighter |
| `Sources/MacDownKit/Preview` | `WKWebView` preview, custom URL scheme handler |
| `Sources/MacDownKit/Views` | SwiftUI document window, split view, toolbar |
| `Sources/MacDownKit/Preferences` | Preferences model and Settings window |
| `Sources/MacDownKit/App` | Menus, app delegate, plug-ins, shell utility hand-off |
| `Sources/MacDownKit/Resources` | Styles, themes, Prism, MathJax config, Mermaid, Graphviz, template |
| `Sources/macdown-cmd` | The `macdown` shell utility |
| `App` | `@main` app, Info.plist, asset catalog, string catalog, localized credits |
| `Tools/import_localizations.py` | Imports the original app's translations into the string catalog |
| `Tests/MacDownKitTests` | Swift Testing suite (ported from the original XCTest suite, plus renderer and editor tests) |
| `project.yml` | XcodeGen spec for the app and shell utility targets |

## How the original maps onto the port

| Objective-C | Swift |
|-------------|-------|
| `MPDocument` (NSDocument + xib) | `MarkdownDocument` (`ReferenceFileDocument`), `DocumentController`, `DocumentView` |
| `MPRenderer` | `MarkdownParser` (hoedown bridge, background-safe), `PageBuilder`, `Renderer` |
| `MPAsset`, handlebars-objc | `Asset`, `HTMLTemplate` (minimal Handlebars subset) |
| `MPPreferences` (PAPreferences) | `Preferences` (`@Observable`, same user defaults keys) |
| MASPreferences panes (xibs) | `SettingsView` (SwiftUI `Settings` scene) |
| `MPEditorView`, `NSTextView+Autocomplete` | `EditorTextView`, `NSTextView+Autocomplete.swift` |
| `HGMarkdownHighlighter` | `MarkdownHighlighter` |
| `MPDocumentSplitView` | `DocumentSplitView` |
| `MPToolbarController` | `DocumentToolbar` (customizable SwiftUI toolbar) |
| `MainMenu.xib` | `MacDownCommands` |
| `MPMainController` | `MacDownAppDelegate`, `AppSupport` |
| WebView + private API | `WKWebView`, `pageZoom`, `WKURLSchemeHandler`, script message handlers |
| `macdown-cmd` (GBCli) | `macdown-cmd/main.swift` |
| LibYAML / YAML.framework, M13OrderedDictionary | [Yams](https://github.com/jpsim/Yams) (order-preserving) |

The preview is served through a custom `x-macdown-preview://` scheme that
maps onto the file system, because `WKWebView` doesn't let pages loaded from
a string read local files. Relative links and images resolve against the
document's location exactly as before.

## Differences from the original

- **Bundle identifier** is `io.github.levous.macdown-swift`, so the port can be
  installed next to the original. Preferences therefore start fresh (the keys
  are the same; copy the original's plist to migrate).
- **Removed:** Sparkle updates, the Touch Bar, AppleScript dictionary, and the
  `data.map`/`treats.map` easter eggs.
- **Localization:** the original translations (21 locales; the original's `ar`,
  `de-DE` and `sk-SK` string tables were empty) were imported
  into `App/Localizable.xcstrings` by `Tools/import_localizations.py`, along
  with each locale's `Credits.rtf`. Strings that are new in the port (or were
  never translated in the original, such as the link error alerts) fall back
  to English. Re-run the script after adding UI strings:
  `python3 Tools/import_localizations.py /path/to/original/macdown`.
- **MathJax** loads directly from the CDN (it always needed an Internet
  connection; the bundled loader shim is no longer needed).
- **Ensure newline at end of file** adds the newline to the saved file
  rather than inserting it into the editor.
- **Window state** is restored by SwiftUI rather than saved per file path;
  the split ratio is stored per window.
- **Save panel** uses SwiftUI's default name; export panels still suggest a
  name from the front matter title or first heading.
- Following a link to a missing file with "Automatically create files for
  link targets" on creates an empty file and opens it (the original opened an
  unsaved document for that path). The shell utility does the same for
  nonexistent paths.

## Debug self-check

Debug builds write a JSON report of each rendered preview (Prism tokens, TOC
links, images, stylesheets, word count, editor highlighting) plus PNG
snapshots when `MACDOWN_DEBUG_REPORT` is set to a directory, e.g.
`open -a MacDown.app --env MACDOWN_DEBUG_REPORT=/tmp/report file.md`.
Adding `--env MACDOWN_DEBUG_EDIT=1` also types a character, checks the
document is marked edited, and undoes it.

## Regenerating the highlighter parser

`Sources/CPegMarkdown/pmh_parser.c` is generated from PEG Markdown Highlight's
`pmh_grammar.leg` with `greg`. To regenerate it, run `make` in the original
repository's `Dependency/peg-markdown-highlight` directory and copy
`pmh_parser.c` here.

## License

MacDown is released under the MIT license; see `LICENSE`. Third-party
licenses are in `Licenses/`.

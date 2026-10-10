# MacDown (Swift) architecture

How MacDown (Swift) is built, and the decisions behind it. For what the app
does and how to install it, see the [README](../README.md); for how it relates
to the original MacDown, see [MACDOWN-PORT.md](MACDOWN-PORT.md).

## Overview

MacDown is a SwiftUI document app. Each window edits one Markdown file: an
`NSTextView` editor on one side, a `WKWebView` preview on the other. Almost all
code is in the `MacDownKit` Swift package; the app target only wires up the
scene and the app delegate.

```
 editor text ──► Renderer (background task) ──► PageBuilder ──► PreviewController (WKWebView)
      │               │ parse result                                 │ metrics (scroll, word count)
      │               ▼                                              ▼
      └──────► MarkdownHighlighter ◄─────── spans ──── DocumentController (one per window)
```

`DocumentController` is the per-window `@MainActor` coordinator: it owns the
editor, preview, renderer and highlighter, observes text and preference
changes, and implements the formatting, saving and export actions.

## Code layout

| Path | Contents |
|------|----------|
| `Package.swift` | Swift package with everything except the app entry point |
| `Sources/CHoedown` | hoedown 3.0.7 plus MacDown's renderer patches (`hoedown_html_patch.c`) — being replaced, see [Markdown engine](#markdown-engine) |
| `Sources/CPegMarkdown` | PEG Markdown Highlight parser (C) — being replaced |
| `Sources/MacDownShared` | Constants shared by the app and the shell utility |
| `Sources/MacDownKit/Document` | Parsing, page assembly, the document model and per-window controller |
| `Sources/MacDownKit/Document/Model` | The cmark-gfm document model: `CMarkTree`, `LineIndex`, `ProtectedSource`, `MarkdownDocumentModel`, `HighlightMapper` |
| `Sources/MacDownKit/Editor` | `NSTextView` subclass, editing helpers, syntax highlighter, theme parser |
| `Sources/MacDownKit/Preview` | `WKWebView` preview, custom URL scheme handler |
| `Sources/MacDownKit/Views` | SwiftUI document window, split view, toolbar |
| `Sources/MacDownKit/Preferences` | Preferences model and Settings window |
| `Sources/MacDownKit/App` | Menus, app delegate, saving dialogs, plug-ins, shell utility hand-off |
| `Sources/MacDownKit/Resources` | Styles, themes, Prism, MathJax config, Mermaid, Graphviz, template, help |
| `Sources/macdown-cmd` | The `macdown` shell utility |
| `App` | `@main` app, Info.plist, asset catalog, string catalog, localized credits |
| `Tools` | Release script, localization import, window capture for checks |
| `Tests/MacDownKitTests` | Swift Testing suite, fixtures and the migration corpus |
| `project.yml` | XcodeGen spec for the app and shell utility targets |
| `docs/` | This document, the migration intent and PRD |

## Render pipeline

1. `DocumentController` observes editor text and preference changes.
2. `Preferences.renderSettings` turns preferences into `RenderSettings`:
   `ParseSettings` (Markdown options, and the hidden `markdownEngine`) plus
   `PageSettings` (styles, Prism, MathJax, Mermaid, Graphviz, template).
3. `Renderer.parse` parses in a detached task; a generation counter discards
   results of superseded parses. Today the HTML comes from `MarkdownParser`
   (hoedown, bridged through C callbacks), which also renders front matter
   (Yams) as a table, substitutes `[TOC]`, and collects code block languages
   for Prism. With `markdownEngine = swiftMarkdown` the same task also builds
   the `MarkdownDocumentModel` (see [Markdown engine](#markdown-engine)).
4. `PageBuilder` (pure functions) builds the full page with `HTMLTemplate` (a
   minimal Handlebars subset) and `Asset` (linked or embedded CSS/JS). The
   preview, HTML export and PDF export use the same builder with different
   embedding options.
5. `PreviewController` loads the page into the `WKWebView`. When only the body
   changed (between the `<!--macdown-body-start/end-->` markers, preview only),
   it swaps the body in place and re-runs the page scripts instead of
   reloading, so the scroll position survives edits.

**Preview URLs.** Pages loaded from a string can't read local files in
`WKWebView`, so file URLs are rewritten to `x-macdown-preview://local/<path>`
(`PreviewURL`) and served by `LocalFileSchemeHandler`. Relative links and
images resolve against the document's location as in the original.

**Scroll sync.** Editor and preview are aligned by anchors (headers, images,
code blocks) found in the source and reported by the page, mapped through
`ScrollMap`, so unequal pane widths and tall images stay aligned in both
directions. The migration moves this to source-line anchors from the parse.

## Editor and highlighting

`EditorTextView` (an `NSTextView` subclass) is hosted in SwiftUI. The editing
helpers (list and quote continuation, auto-pairing, toggling markup,
indenting) are in `NSTextView+Autocomplete.swift`, called from
`DocumentController`'s text view delegate methods.

`MarkdownHighlighter` styles only the visible range, from spans keyed by PEG
Markdown Highlight's element types (`H1`, `EMPH`, `CODE`, …) so the original
`.style` themes apply unchanged. Themes are parsed by `ThemeStyle`, a Swift
port of the C style parser. Spans come either from the PEG C parser (today's
default) or, with the new engine, from `HighlightMapper` via the shared
document model, which adds `NOTE` (footnotes), `MATH`, `HIGHLIGHT` and
`SUPERSCRIPT`.

## Saving

The editor edits a draft; `MarkdownDocument.text` is the saved state. With
"Save changes automatically" off (the default), the document only receives
the draft on Save, and the editor records undo on the controller's own
`UndoManager`, so SwiftUI and AppKit never see changes to autosave. With it
on, every edit is copied into the document and AppKit autosaves.

- File ▸ Save, Save As… and Duplicate are handled by `DocumentResponder`,
  inserted in the responder chain before the window: SwiftUI's window would
  otherwise pass them to the NSDocument, which holds the stale text.
- Closing goes through `WindowCloseGuard`, a forwarding wrapper around
  SwiftUI's window delegate; quitting through `applicationShouldTerminate`.
  Both ask "You have unsaved changes." via `DocumentSaving`.
- External changes to an open file reload it, or ask when there are unsaved
  changes.

## App and shell utility

`macdown-cmd` and the app communicate only through the shared user defaults
suite and the keys in `MacDownShared/Globals.swift`. Changing those keys or
the bundle identifier (`io.github.levous.macdown-swift`) means changing both
sides. Preference keys match the original app's user defaults keys.

## The original app

The port's goals, its differences from the original, and a map of the
original's classes onto this code are in [MACDOWN-PORT.md](MACDOWN-PORT.md).

## Markdown engine

The port started on the original's engines: patched hoedown for HTML and PEG
Markdown Highlight for the editor, two C parsers that parse every edit twice
and disagree in places. They are being replaced by **cmark-gfm**, used
directly, so one parse feeds the preview, export, highlighting and scroll
sync. The plan, requirements and progress are in
[docs/intents/swift-markdown-migration.md](intents/swift-markdown-migration.md),
[docs/prd/swift-markdown-migration-prd.md](prd/swift-markdown-migration-prd.md)
and `.ralph/fix_plan.md`.

cmark-gfm is the default. For one release the original engines stay
selectable through a hidden setting
(`defaults write io.github.levous.macdown-swift markdownEngine hoedown`;
`swiftMarkdown`, the historical name, means cmark-gfm); then hoedown and PEG
Markdown Highlight are removed.

The new model (`Sources/MacDownKit/Document/Model`):

- `CMarkTree` parses with cmark-gfm: source positions and footnotes always,
  the `table`, `strikethrough` and `tasklist` extensions always, `autolink`
  and smart punctuation only when their settings are on.
- `ProtectedSource` hides math and front matter from the parser by replacing
  them with filler of the same byte length, so every source position stays
  valid.
- `LineIndex` converts cmark's UTF-8 line/column positions into the UTF-16
  ranges the editor uses.
- `MarkdownDocumentModel` is built inside the parse task and keeps only
  `Sendable` results (blocks, highlight spans; later the HTML); the C tree
  never leaves the task.

## Decisions

Dated, newest first. The migration intent has the full list for the engine
work.

**Parse with cmark-gfm directly (2026-10-09).** The migration was planned on
Apple's swift-markdown, a Swift wrapper around cmark-gfm. Measured on a
10,000-line document (release build, median): PEG highlighting 20.1 ms;
highlighting from swift-markdown's tree 73.3 ms (124.7 with math and the
opt-in syntax), because converting cmark's C tree into Swift values alone
took 32.6 ms; cmark-gfm used directly, parsing with every extension and
walking every node, 4.5 ms. swift-markdown also doesn't parse footnotes or
bare-URL autolinks, which cmark-gfm does. So the model, highlighter and
renderer walk cmark-gfm's C tree inside the parse task, and swift-markdown is
dropped. Cost: we own a thin wrapper over a C API (`CMarkTree`) instead of a
Swift one. Result: the whole model, editor highlighting and the preview's HTML
together, takes 16.8 ms at default settings, against 19.3 ms for PEG's
highlighting alone, and 19.3 ms with math and every opt-in on.
(Intent Decision 10, finding F8.)

**Standard Markdown always on, extensions opt-in (2026-10-09).** Tables,
fenced code, footnotes, strikethrough, task lists and front matter always
render; highlight, superscript, autolink and smart punctuation (and math,
`[TOC]`, hard wrap, Graphviz) are settings, off by default. Quote (`"…"` as
`<q>`) is dropped. The goal is the most expected, standard behavior with the
greatest feature support.

**Test corpus is generated (2026-10-09).** The migration is checked against
purpose-written Markdown in `Tests/MacDownKitTests/Resources/Corpus` plus the
bundled help, never users' documents.

**Saving through a draft.** Rather than patching SwiftUI's private
document classes to stop autosaving, the editor's text is a draft that only
reaches the document on Save (unless autosave is on). See [Saving](#saving).

**Preview updates in place.** Re-rendering swaps the page body instead
of reloading, so the preview keeps its scroll position while typing.

**Package plus generated project.** Everything that can be built and tested
from the command line is a Swift package; the app target is generated by
XcodeGen from `project.yml`, so the Xcode project isn't checked in.

Decisions about parity with the original app (preferences, bundle
identifier, HTML output) are in [MACDOWN-PORT.md](MACDOWN-PORT.md#port-decisions).

## Development

Requirements: macOS 15 or later, Xcode 27 or later (Swift 6.4), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Strict concurrency is on:
UI types are `@MainActor` and parsing runs off the main actor.

```sh
swift build                 # C libs, MacDownKit, macdown CLI
swift test                  # Swift Testing suite
xcodegen generate           # MacDown.xcodeproj from project.yml (gitignored)
xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Release build
```

New resource directories go in `resources:` in `Package.swift`; edit
`project.yml`, never the generated project.

### Tests

The suite uses Swift Testing, which runs suites in parallel. Suites that drive
a real `DocumentController` with a live `WKWebView` or change
`Preferences.shared` are nested in the serialized `LiveDocumentTests` suite.
The bundled help (`Resources/help.md`) has a live example of every feature
and setting, and `HelpDocumentTests` renders it, checks its highlighting and
loads it in the real preview.

The engine migration is checked by two harnesses that run with every
`swift test` over the corpus (19 generated documents, `help.md`, and a
generated 10,000-line document):

```sh
swift test --filter HTMLDiffHarnessTests        # preview HTML, 9 settings
swift test --filter HighlightDiffHarnessTests   # editor highlight spans

# Write html-diff.md and highlight-diff.md for review:
MACDOWN_DIFF_REPORT=/tmp/diff swift test --filter "DiffHarnessTests"

# Highlighting speed (NFR-1), on demand:
MACDOWN_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
  --filter HighlightBenchmarkTests
```

Intended HTML differences are listed once in
`Tests/MacDownKitTests/Resources/expected-html-diffs.json`; reviewed
highlighting differences are in `HighlightDiffHarnessTests.reviewed`. There is
no CI; run them before merging engine work.

### Checking the running app

Debug builds write a JSON report of each rendered preview (Prism tokens, TOC
links, images, stylesheets, word count, editor highlighting) plus PNG
snapshots when `MACDOWN_DEBUG_REPORT` is set to a directory:
`open -a MacDown.app --env MACDOWN_DEBUG_REPORT=/tmp/report file.md`. Adding
`--env MACDOWN_DEBUG_EDIT=1` also types a character, checks the document is
marked edited, and undoes it. `swift Tools/capture-window.swift MacDown
out.png [title]` screenshots a running window.

Throwaway builds register with LaunchServices under the app's bundle
identifier; unregister them (`lsregister -u`) so documents keep opening in
the installed app.

### Localization

UI strings use `String(localized:)` and live in `App/Localizable.xcstrings`.
The original's translations (21 locales) were imported by
`Tools/import_localizations.py`, which also merges translations of strings
new in the port from `Tools/port_translations.json` (marked as needing
review). Re-run it after adding UI strings:
`python3 Tools/import_localizations.py /path/to/original/macdown`.

### Regenerating the highlighter parser

`Sources/CPegMarkdown/pmh_parser.c` is generated from PEG Markdown Highlight's
`pmh_grammar.leg` with `greg`; don't edit it by hand. To regenerate it, run
`make` in the original repository's `Dependency/peg-markdown-highlight`
directory and copy `pmh_parser.c` here. (It goes away with the engine
migration.)

### Releasing

`Tools/release.sh <version>` bumps the version (in `project.yml` and
`MacDownShared/Globals.swift`), builds and notarizes the app, publishes a
GitHub release and updates the `macdown-swift` cask in
[levous/homebrew-tap](https://github.com/levous/homebrew-tap):

```sh
Tools/release.sh 1.1 --dry-run   # build and check locally, publish nothing
Tools/release.sh 1.1
```

Releases need a "Developer ID Application" certificate and notarization
credentials; see the top of the script.

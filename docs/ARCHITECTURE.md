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
| `Sources/MacDownShared` | Constants shared by the app and the shell utility |
| `Sources/MacDownKit/Document` | Parsing, page assembly, the document model and per-window controller |
| `Sources/MacDownKit/Document/Model` | The cmark-gfm document model: `CMarkTree`, `LineIndex`, `ProtectedSource`, `MarkdownDocumentModel`, `HighlightMapper` |
| `Sources/MacDownKit/Document/HTMLToMarkdown` | Pasted HTML as Markdown: parsing, styles, the walker, the renderer, tables |
| `Sources/MacDownKit/Editor` | `NSTextView` subclass, editing helpers, pasting, syntax highlighter, theme parser |
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
   `ParseSettings` (the opt-in Markdown options; standard Markdown is always
   on) plus `PageSettings` (styles, Prism, MathJax, Mermaid, Graphviz,
   template).
3. `Renderer.parse` builds the `MarkdownDocumentModel` in a detached task
   (see [Markdown engine](#markdown-engine)); a generation counter discards
   results of superseded parses. The model's HTML renders front matter
   (Yams) as a table, substitutes `[TOC]`, and collects code block languages
   for Prism; its highlight spans go to the editor.
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

**Scroll sync.** Editor and preview are aligned by anchors: the preview marks
every block with its source line (`data-source-line`), the page reports where
each one is, and the editor finds the same lines in its layout. `ScrollMap`
pairs them by line, so unequal pane widths and tall images stay aligned in
both directions.
The page follows the editor smoothly: `PreviewController.scroll(to:animated:)`
hands the offset to `MacDownScroll`, a script in the page that eases towards
the latest target each animation frame. While the editor scrolls, each new
offset just moves the target, so the preview moves continuously instead of in
steps. It jumps instead after loading a new page and after resizes, with
reduced motion, and when
WebKit draws no frames (hidden windows, tests). The page tags its scroll
reports with whether the user scrolled, so the preview's own movement never
takes the lead from the editor.

## Editor and highlighting

`EditorTextView` (an `NSTextView` subclass) is hosted in SwiftUI. The editing
helpers (list and quote continuation, auto-pairing, toggling markup,
indenting) are in `NSTextView+Autocomplete.swift`, called from
`DocumentController`'s text view delegate methods.

`MarkdownHighlighter` styles text from spans keyed by `HighlightElement`, PEG
Markdown Highlight's element types (`H1`, `EMPH`, `CODE`, …), so the original
`.style` themes apply unchanged. Themes are parsed by `ThemeStyle`. Both are
Swift ports of PEG Markdown Highlight's code (its license is kept in
`Licenses/`); the C library is no longer used. The spans come from
`HighlightMapper` via the shared document model, which adds `NOTE`
(footnotes), `MATH`, `HIGHLIGHT` and `SUPERSCRIPT`.

New spans are applied straight away to the visible text and a screen above
and below it. When the editor scrolls, the highlighter styles whatever of
that range isn't styled yet in the same pass, before it's drawn. It keeps
track of the styled ranges in `highlightedRanges`, cleared on every text
edit or new spans. The rest of the document is styled by an idle pass, a few
milliseconds per main queue turn, nearest the visible text first. It starts
0.5 s after the last edit, so typing restyles only around the visible text.
`DocumentController` skips its scroll-sync re-measurement for the idle pass's
storage edits and runs it once, from `onIdlePassFinished`. Styling text above
the visible area keeps the visible text in place, because themes can change
heading font sizes.

### Pasting

Paste, Services and text dropped from other apps all go through
`EditorTextView.readSelection(from:)` and `readSelection(from:type:)`
(`EditorTextView+Paste.swift`). `PasteboardContent` reads the clipboard: HTML
(or a WebKit web archive's page), else RTF or RTFD exported to HTML by AppKit,
else image data when there's no text, plus the address relative links resolve
against. `HTMLToMarkdown` (`Document/HTMLToMarkdown`) parses the HTML with
`XMLDocument` (Tidy), resolves each element's bold, italic, strikethrough and
monospace from tags, `<style>` classes and inline styles, walks the tree into
blocks of styled text runs, and renders Markdown with the editing settings
(list marker, indentation), escaping only what would change the parse. Runs
are grouped into emphasis markers by the renderer because apps like Google
Docs write every run as a flat styled span.

The paste is skipped, so the text view pastes plain text, for content that
looks like code (all monospace, no structure), inside a code block (a fence
scan above the caret, or the latest parse's blocks for indented code), with
the setting off (images still paste), and during Paste and Match Style. The
insertion is its own undo step (`breakUndoCoalescing`), and blocks get blank
lines around them. A converted paste shows a "Paste as Plain Text" button
that's dismissed by the next edit, Escape, moving the selection out, or
scrolling away. The editor's own copies write plain text only, so they're
never converted.

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
and disagree in places. They were replaced by **cmark-gfm** (swift-cmark),
used directly, so one parse feeds the preview, export, highlighting and
scroll sync, and removed on 2026-10-22. The plan and requirements are in
[docs/intents/swift-markdown-migration.md](intents/swift-markdown-migration.md)
and [docs/prd/swift-markdown-migration-prd.md](prd/swift-markdown-migration-prd.md).
The renderer still writes hoedown's markup where CommonMark agrees, checked
against hoedown's output recorded before it was removed
(`Tests/MacDownKitTests/Resources/engine-snapshots.json`).

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
  `Sendable` results (blocks, highlight spans, the HTML); the C tree
  never leaves the task.

## Decisions

Dated, newest first. The migration intent has the full list for the engine
work.

**hoedown and PEG Markdown Highlight are removed (2026-10-22).** cmark-gfm
has been the only engine in practice since 2026-10-09; the hidden
`markdownEngine` setting, `MarkdownParser`, the hoedown scroll anchors, the
highlighter's PEG parse and both C targets are gone, so the package has no C
code. Before the removal, the outputs the port has to match (hoedown's HTML
and escaping, PEG's theme parsing) were recorded as test fixtures. The PEG
license stays because the highlighter and theme parser are ports of its code
(`Licenses/README.md`); hoedown's goes.

**Paste conversion parses HTML with `XMLDocument` (2026-10-21).** Pasting
formatted text converts the clipboard's HTML (or RTF, via AppKit's HTML
export) to Markdown. Foundation's `XMLDocument` with `.documentTidyHTML`
parses it, so there's no new dependency: a spike over clipboard fixtures from
Google Docs, Word, browsers, MacDown's preview and code editors kept all their
text. Tidy only knows HTML 4, so HTML5 block elements are renamed to `div`
before parsing. Details are in
[the paste intent](intents/paste-formatted-text.md#decisions).

**Highlight before drawing, then the rest when idle (2026-10-12).** The
editor used to style the visible range 100 ms after scrolling stopped, so a
continuous scroll showed unstyled text. Now newly visible text, with a
screen of overscan, is styled synchronously in the scroll notification, and
an idle pass styles the rest of the document. Measured on a 256,000-character
document (release build, Tomorrow+ theme, a real `DocumentController`): a
scroll step costs 0.06 ms on average and at most 2 ms; restyling after a
parse (the visible text and the overscan) about 4 ms; and the whole document
is styled about 0.2 s after it opens. The idle pass adds no main-thread stalls
beyond those opening already causes (parsing, loading the preview). It ends
with one scroll-sync re-measurement, a full editor layout (about 36 ms at that
size), which the old code paid at every scroll stop. See [markedit-vs-macdown-swift.md](markedit-vs-macdown-swift.md).

**Smooth, live scroll sync (2026-10-12).** The preview followed the editor
with an instant `window.scrollTo` per editor frame, sent across processes, so
it moved in uneven steps and changed speed at anchors. MarkEdit's preview
glides smoothly but only syncs once the editor stops, and never the other
way. We keep the live, two-way sync and ease in the page: each frame covers
`1 - e^(-dt/60 ms)` of the remaining distance, at least a pixel, so a moving
target is followed without restarting. The 0.25 s window that told the page's
own scrolling from the user's is replaced by the page tagging its reports, as
an animation would outlast it.

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

The renderer is checked against hoedown's output and PEG Markdown
Highlight's style parser, recorded before they were removed
(`Resources/engine-snapshots.json`, `EngineSnapshots`). The corpus (19
generated documents, `help.md`, and a generated 10,000-line document) is
rendered by `CorpusTests` and round-tripped by `PasteRoundTripTests` below.
The two engine-comparison harnesses that guided the migration were retired
with hoedown; the differences they found are summarized in
[MACDOWN-PORT.md](MACDOWN-PORT.md).

```sh
# Highlighting speed against PEG Markdown Highlight's recorded time, on demand:
MACDOWN_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
  --filter HighlightBenchmarkTests
```

Pasting is checked the same way: `PasteRoundTripTests` renders each corpus
document, converts the HTML back with `HTMLToMarkdown` and renders that
again; `Resources/reviewed-paste-diffs.json` lists the reviewed differences
(rewrites for whole kinds of markup, such as footnotes, and single hunks).
`MACDOWN_DIFF_REPORT` writes `paste-round-trip.md`. Clipboard fixtures are
in `Resources/Paste/<source>/` (one file per pasteboard type, a manifest,
and the expected Markdown); `Tools/capture-pasteboard.swift` saves new ones,
from generated content only (`Paste/sample.md`). `PasteLiveTests` use the
real menu actions on the general pasteboard and put back what was there.

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
The script writes the whole catalog in its own JSON layout, while Xcode
saves it in another (`"key" : value`, its own key order, `extractionState`
on each entry), so a run after Xcode has saved the catalog rewrites every
line. If it has, commit only the new entries (2026-10-21: the paste strings
were added that way).

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

# MacDown port

This app is a port of [MacDown](https://github.com/MacDownApp/macdown), the
open source Markdown editor for macOS by Tzu-ping Chung and contributors, from
Objective-C, AppKit and the legacy WebView to **Swift 6**, **SwiftUI** and
**WKWebView**. This document covers what the port keeps from the original,
what it changes, and how the original's code maps onto it. How the app itself
is built is in [ARCHITECTURE.md](ARCHITECTURE.md).

## What carries over

- **Features:** the editor and its helpers, live preview with Prism, MathJax,
  Mermaid and Graphviz, scroll sync, export and printing, the toolbar and the
  Format/View menus with the original keyboard shortcuts, the `macdown` shell
  utility, the `x-macdown://open?url=…` URL scheme, and plug-ins.
- **Settings:** preference keys are the original's, so a copied preferences
  file carries over (see the bundle identifier below).
- **Themes and styles:** the original `.style` editor themes and preview CSS,
  read from the same `~/Library/Application Support/MacDown` folder, which the
  two apps share.
- **Translations:** the original's 21 localizations were imported (its `ar`,
  `de-DE` and `sk-SK` string tables were empty); text new in the port is
  translated for review or shown in English.

## Installing next to the original

The app is called `MacDown.app`, like the original, so installing it into
`/Applications` replaces an installed copy of the original (the Homebrew cask
refuses to install alongside the `macdown` cask). Its bundle identifier is
`io.github.levous.macdown-swift`, so it keeps its own preferences: they start
fresh, and the original's plist can be copied over to migrate.

## Differences from the original

- **Saving** is explicit by default: edits mark the window edited, ⌘S
  or the toolbar's Save button (enabled when there are unsaved changes)
  saves, and closing a window or quitting with unsaved changes asks "You have
  unsaved changes." (Save or Save and Quit / Discard / Cancel). Turn on Settings ▸ General ▸ "Save
  changes automatically" for macOS's usual save-in-place behavior.
- **Changes on disk:** when another application changes an open file, the
  window loads the new text right away if it has no unsaved changes. If it
  has any, it asks once the window is in front: Keep My Changes (the file is
  overwritten at the next save) or Revert.
- **Underline** is HTML: the Underline button and ⌘U insert `<u>…</u>`, and
  underscores follow standard Markdown (`_text_` italic, `__text__` bold).
  The original's Underline setting, which made `_text_` underline, is gone.
- **Standard Markdown is always on:** tables, fenced code blocks, footnotes,
  strikethrough, intra-word emphasis, task lists and Jekyll front matter
  render without a setting, and their settings are gone (saved values are
  left in user defaults). Settings ▸ Markdown keeps only the non-standard
  syntax, off by default: Highlight, Superscript, Autolink and Smart
  punctuation (the original's Smartypants, same key). The Quote setting
  (`"…"` as `<q>`) is dropped; use Smart punctuation for curly quotes.
- **Editing defaults** for new installs follow common Markdown conventions:
  `-` list marker, newline at end of file, and spaces instead of tabs.
  Existing installs keep their settings.
- **Mermaid** is version 12 (the original bundled 8.4), so newer diagram
  types such as mindmaps, timelines and C4 work. Diagrams use Mermaid's
  `forest` theme, and syntax errors are shown under the diagram's source.
- **MathJax** loads directly from its CDN (math always needed an Internet
  connection).
- **Markdown engine:** the original's two parsers are replaced by one,
  [cmark-gfm](https://github.com/swiftlang/swift-cmark), which follows
  CommonMark and GitHub Flavored Markdown; where the results differ is listed
  below. For one release the original's engine can be turned back on with
  `defaults write io.github.levous.macdown-swift markdownEngine hoedown`.
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

## Markdown differences with the new engine

The port renders with cmark-gfm instead of the original's hoedown (see
[ARCHITECTURE.md](ARCHITECTURE.md), "Markdown engine"). It follows
CommonMark and GitHub Flavored Markdown, so some documents render
differently from the original. These are the differences found on the test
corpus; each is reviewed in
`Tests/MacDownKitTests/Resources/reviewed-html-diffs.json`:

- **Emphasis:** underscores don't emphasize inside words (`snake_case_name`
  stays as typed), `***text***` nests as emphasis inside strong, and nested
  emphasis that hoedown missed now works.
- **Strikethrough:** `~single tildes~` strike through too.
- **Line breaks:** a backslash at the end of a line is a line break. With
  "Render newline literally", a line ending in two spaces gets one break,
  not two, and tight list items break too.
- **Headers:** a `#` must be followed by a space (`#Not` is text), more than
  six `#` is a paragraph, and a setext header (`===`/`---` underline) can
  span several lines.
- **Lists:** `1)` starts a list, an ordered list keeps its start number,
  changing the bullet character starts a new list, a list can interrupt a
  paragraph, and loose and tight lists follow CommonMark.
- **Task lists:** `[X]` counts as checked, and `[ ]` needs a space after it.
- **Block quotes:** quotes separated by a blank line are separate quotes.
- **Code:** a fence inside a code span stays inline.
- **Links:** a link destination in angle brackets may contain spaces.
- **Footnotes:** a footnote referenced twice links both times, and the
  superscript setting no longer turns footnote syntax into superscript.
- **HTML:** HTML blocks end where CommonMark says; an unknown entity such as
  `&foo;` shows as typed; `&#0;` is the replacement character.
- **Math:** amounts like "$5 and $10" aren't math, even with dollar
  delimiters on.
- **Table of contents:** entries leave out HTML in headers, such as anchors.
- **Highlight and superscript** (`==text==`, `x^2`) work within plain text,
  not around other formatting: `==*a*==` isn't highlighted.

## How the original maps onto the port

| Objective-C | Swift |
|-------------|-------|
| `MPDocument` (NSDocument + xib) | `MarkdownDocument` (`ReferenceFileDocument`), `DocumentController`, `DocumentView` |
| `MPRenderer` | `MarkdownDocumentModel` and `HTMLRenderer` (cmark-gfm), `PageBuilder`, `Renderer`; `MarkdownParser` (the hoedown bridge, for one release) |
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

## Port decisions

**Same preferences, own bundle identifier.** User defaults keys match the
original so settings migrate by copying the plist; the bundle identifier
differs so the port has its own preferences domain and can't corrupt the
original's.

**Byte-identical HTML with the original is dropped (2026-10-09).** Until the
engine change, the port rendered with the original's patched hoedown, and its
HTML matched the original byte for byte. The new cmark-gfm renderer follows
CommonMark and GitHub Flavored Markdown instead; where its output differs from
the original is reviewed with the diff harnesses and listed under
"Differences from the original". (See [ARCHITECTURE.md](ARCHITECTURE.md),
"Markdown engine".)

**Removed rather than ported:** Sparkle updates (releases go through GitHub
and Homebrew), the Touch Bar, the AppleScript dictionary, and the easter eggs.

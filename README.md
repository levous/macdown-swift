# MacDown (Swift)

A port of [MacDown](https://github.com/MacDownApp/macdown), the open source
Markdown editor for macOS, from Objective-C/AppKit/WebView to **Swift 6** and
**SwiftUI**.

![MacDown Screenshot](Screenshots/macdown-and-i.png)

You write Markdown on one side and see the formatted result on the other as
you type. The port keeps MacDown's features, preferences and editor themes:

- Live preview of standard Markdown (CommonMark and GitHub Flavored Markdown:
  tables, fenced code, task lists, strikethrough, footnotes) and Jekyll front
  matter, plus optional highlight, superscript, autolinks and smart
  punctuation.
- Editor syntax highlighting with the original `.style` themes.
- Code highlighting with Prism, math with MathJax, Mermaid and Graphviz
  diagrams, and a `[TOC]` table of contents.
- The editor helpers: list and blockquote continuation, auto-pairing of
  brackets and quotes, smart Home, tab/space conversion, toggling markup,
  headers, lists, links and images.
- Scroll synchronization between editor and preview, word count, HTML and
  PDF export, printing, customizable toolbar and the full Format/View menus
  with the original keyboard shortcuts.
- The `macdown` shell utility (open files from a terminal or pipe text in),
  the `x-macdown://open?url=…` URL scheme, and plug-ins.
- Your settings carry over (the preference names are unchanged), and styles
  and themes are read from the same `~/Library/Application Support/MacDown`
  folder.

How it's built is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installing

MacDown needs macOS 15 or later. Signed and notarized builds are published on
the [Releases](https://github.com/levous/macdown-swift/releases) page.

With [Homebrew](https://brew.sh), which also links the `macdown` shell
utility:

```sh
brew install --cask levous/tap/macdown-swift
```

Or download `MacDown-<version>.zip` from the
[latest release](https://github.com/levous/macdown-swift/releases/latest),
unzip it and move `MacDown.app` to `/Applications`. To use the shell utility
without Homebrew, link it into your `PATH`:

```sh
ln -s /Applications/MacDown.app/Contents/SharedSupport/bin/macdown /usr/local/bin/macdown
```

The app is called `MacDown.app`, like the original MacDown, so it replaces an
installed copy of the original (the cask refuses to install alongside the
`macdown` cask). Both apps share the styles and themes in
`~/Library/Application Support/MacDown`.

## Building from source

You need macOS 15 or later, Xcode 27 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
swift test                 # build the core library and run the tests
xcodegen generate          # generate MacDown.xcodeproj
open MacDown.xcodeproj
```

How the app is built, the decisions behind it, and the development workflow
(tests, releases, localization) are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Differences from the original

- **Bundle identifier** is `io.github.levous.macdown-swift`, so the port can be
  installed next to the original. Preferences therefore start fresh (the keys
  are the same; copy the original's plist to migrate).
- **Removed:** Sparkle updates, the Touch Bar, AppleScript dictionary, and the
  `data.map`/`treats.map` easter eggs.
- **Localization:** the original's 21 translations are kept; text that is
  new in the port is translated for review or shown in English.
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
- **Markdown engine:** the original's two parsers are being replaced by one,
  [cmark-gfm](https://github.com/swiftlang/swift-cmark), which follows
  CommonMark and GitHub Flavored Markdown; until it ships, rendering uses the
  original's engine. Where the results differ is listed here when it ships.
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

## License

MacDown is released under the MIT license; see `LICENSE`. Third-party
licenses are in `Licenses/`.

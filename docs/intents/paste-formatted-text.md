# Paste formatted text as Markdown

- **Status:** Accepted (decisions recorded below)
- **Date:** 2026-10-21
- **Scope:** When the user pastes formatted text (from a web page, Google Docs, Word, Pages, Notion, MacDown's own preview), insert equivalent Markdown instead of the plain text. Applies to the editor's Paste command; Paste and Match Style keeps pasting plain text. Also covers pasting image data (screenshots), inserted as embedded images like dropped image files.

## Principle

**Paste what the user sees, written the way they would have typed it.**

- Formatting that has a Markdown equivalent (headings, emphasis, links, lists, code, quotes, tables, images) becomes that Markdown.
- Anything without one is dropped, not approximated: colors, fonts, sizes, alignment.
- The output follows the user's editing settings (list marker, tabs or spaces) and the same conventions as the editor's own helpers, so pasted text looks like the rest of the document.
- Code is never "improved". Text copied from a code editor stays verbatim.
- There's always a way to paste plain text, including right after a converted paste.

## Why

- Moving existing writing into MacDown (notes, docs, web articles) means retyping its formatting today. The editor is plain text (`EditorTextView`: `isRichText = false`), so `NSTextView` pastes only the clipboard's plain-text representation and the structure is lost.
- The clipboard already carries that structure. Browsers, Google Docs, Notion, Word and WKWebView write `public.html`; Pages, TextEdit and Word write RTF.
- Comparable editors (Obsidian, Typora, Bear) convert on paste, so users expect it.

## Goals

1. Pasting from a browser, Google Docs, Word, Pages or MacDown's preview produces clean, idiomatic Markdown that renders like the source.
2. Pasting from code editors and terminals (VS Code, Xcode, Terminal) is unchanged: the plain text.
3. A paste undoes in one step, and a converted paste can be swapped for plain text in one click.
4. Conversion is synchronous, fast for typical pastes (well under 50 ms for a long article) and has no new dependencies.
5. The converter is pure, `Sendable` and tested over the existing corpus.

## Non-goals

- Converting dropped files (`.docx`, `.html`, `.rtf`) or an "Import" command. The converter makes that easy later; it's a separate intent.
- Copy as Markdown from other apps, or changing what MacDown puts on the clipboard.
- Downloading remote images or embedding them as data URIs. Image URLs are kept as they are.
- Preserving styling with raw inline HTML (`<span style>`, `<font>`, `<u>`).
- Round-tripping MacDown's extended syntax (math, `[TOC]`, `==highlight==`, Mermaid/Graphviz) exactly. Best effort only.

## Current state

| Concern | Today | Code |
|---|---|---|
| Paste | `NSTextView`'s default: plain text, because the view isn't rich text | `Editor/EditorTextView.swift` |
| Dropping images | Image files dropped on the editor become `![](data:…;base64,…)` | `EditorTextView.performDragOperation` |
| Clipboard writing | Copy HTML writes the rendered body | `DocumentController` (Copy HTML) |
| Editing style | Unordered list marker setting (`*`, `-`, `+`), tabs or spaces | `Preferences.editorUnorderedListMarker`, `editorConvertTabs` |
| Menus | Edit menu is SwiftUI's default; MacDown adds groups and the Format menu | `App/MacDownCommands.swift` |

## Design

### Where it hooks in

`EditorTextView` overrides `paste(_:)`:

1. If the setting is off, or the selection is inside a fenced or indented code block (from the document model's blocks), call `super` (plain text).
2. Read the clipboard, in order of preference:
   - `public.html` (`NSPasteboard.PasteboardType.html`)
   - `public.rtf` / `com.apple.flat-rtfd`: converted to HTML with `NSAttributedString(rtf:)` then `data(from:documentAttributes: [.documentType: .html])`, so there's one conversion path. The converter recognizes the classes and styles AppKit's HTML export writes.
   - image data only (`public.png`, `public.tiff`, as a screenshot puts there): see "Image data" below.
   - otherwise `super`.
3. If the source looks like code (see "Code editors" below), call `super`.
4. Convert with `HTMLToMarkdown` and insert with `insertText(_:replacementRange:)`, so the paste is one undo step and goes through the same `shouldChangeText`/delegate path as typing (autosave and the draft see it normally).

`pasteAsPlainText(_:)` (Paste and Match Style, ⌥⇧⌘V) keeps calling `super`, so plain text is always one shortcut away. When the setting is off, Edit ▸ Paste as Markdown (⌥⌘V) runs the conversion explicitly.

After a converted paste, the inline plain-text option appears (see below).

The same path serves `readSelection(from:type:)` so Services and text drags from other apps behave like paste.

### Inline "Paste as plain text"

After a paste that was converted (the inserted text differs from the clipboard's plain text), a small button labeled "Paste as Plain Text" appears just below the end of the pasted range, like Notion's.

- Clicking it replaces the pasted range with the clipboard's plain text, as one undoable change (Undo brings the Markdown back).
- It's dismissed on the next edit, a selection change outside the pasted range, scrolling the range out of view, Escape, or another paste. It never takes focus from the editor, so typing continues normally.
- It's an accessibility element with its label, and the same action is reachable without the mouse: Undo then Paste and Match Style.
- The editor keeps the pasted range and the plain text only while the button is shown.

### Image data

When the clipboard holds image data and no HTML, RTF or text (a screenshot copied with ⌃⇧⌘4, an image copied from Preview or a browser's Copy Image), Paste inserts `![](data:<mime>;base64,…)`, the same markup as dropping an image file (`EditorTextView.performDragOperation`). PNG and JPEG are kept as they are; TIFF (what screenshots and many apps write) is converted to PNG. Images inside an HTML paste keep their `src` and aren't fetched or embedded. Image paste doesn't depend on the conversion setting, since there's no plain-text alternative and dropping images is always on; both share one helper for the markup.

### The converter

`Document/HTMLToMarkdown.swift` in MacDownKit: a pure `Sendable` struct with options (list marker, indent string, base URL), `func convert(_ html: String) -> String`.

- **Parsing:** `XMLDocument(xmlString:options: [.documentTidyHTML])`, which repairs real-world HTML into a tree. No dependency, no C (CLAUDE.md: "Don't add C"). Phase 0 confirms it copes with the fixtures below; SwiftSoup is the fallback if it doesn't.
- **Walk:** a recursive visitor with a block context (list depth and kind, inside a quote, inside `pre`, inside a table) and an inline context (bold, italic, strikethrough, code, link), producing Markdown blocks joined by blank lines.

| HTML | Markdown |
|---|---|
| `h1`–`h6` | ATX `#` headings |
| `p`, `div` with text, `br` | paragraphs; `br` inside a paragraph is a hard break (backslash) |
| `strong`, `b`, `font-weight` ≥ 600 | `**x**` (always `**`/`*`; no setting) |
| `em`, `i`, `font-style: italic` | `*x*` (`*` also works inside words, `_` doesn't) |
| `del`, `s`, `strike`, `text-decoration: line-through` | `~~x~~` |
| `code`, `kbd`, monospace font family inline | `` `x` `` with enough backticks to wrap embedded ones |
| `pre` (optionally `pre > code`) | fenced block; language from `class="language-x"`/`lang-x`; fence longer than any run of backticks inside |
| `a href` | `[text](url "title")`; bare `<url>` when text equals the URL; text only when the href is `javascript:` or an in-page `#anchor` from the source page |
| `img` | `![alt](src "title")` |
| `ul`, `ol` (`start`), `li` | nested lists using the user's marker; ordered lists keep their start number; continuation lines indented to the content column |
| `input type=checkbox` in `li` | `- [ ]` / `- [x]` |
| `blockquote` | `> ` prefixed, nested |
| `hr` | `---` (or `***` when the marker setting is `-`, to avoid a setext heading) |
| `table` | GFM pipe table when every cell is inline content and there are no `rowspan`/`colspan`; header from `thead`/`th` or the first row; alignment from `align`/`text-align`. Otherwise the table is kept as raw HTML |
| `sup` / `sub`, `mark`, `u` | text only |
| `script`, `style`, `head`, comments, `meta` | dropped |

- **Text:** collapse whitespace as a browser does (except inside `pre`), decode entities, trim trailing spaces, and escape Markdown in text runs: `\ * _ [ ] < > `` ` `` and `~`; `#`, `>`, `+`, `-`, `=` and `1.`/`1)` only at the start of a line; `|` inside tables.
- **Output:** no more than one blank line between blocks, a trailing newline only if the paste ends with a block, no leading blank lines. If the result is a single paragraph it's inserted inline, without paragraph breaks around it.

### Source quirks

- **Google Docs:** everything is wrapped in `<b style="font-weight:normal" id="docs-internal-guid-…">`; bold, italic and code are inline styles on `span`s; headings are real `h*`. The converter reads styles (`font-weight`, `font-style`, `text-decoration`, `font-family`) rather than trusting tag names, and treats `font-weight: normal` as cancelling an outer `b`.
- **Word (`public.html`):** `mso-*` styles and classes, conditional comments (`<!--[if …]>`), `o:p` elements, lists written as paragraphs with `mso-list` and a bullet in a hidden span. Lists are rebuilt from `mso-list: lN levelM`.
- **Pages / TextEdit (via RTF → HTML):** AppKit writes `p.p1`/`span.s1` classes defined in a `<style>` block. The converter resolves those classes' `font-weight`, `font-style` and `font-family` for bold, italic and monospace, and reads `ul`/`ol` that AppKit writes for `NSTextList`.
- **Web pages:** navigation and layout `div`s, icon fonts, `<picture>`/`srcset`. Relative `href`/`src` resolve against the source URL, which browsers put on the clipboard (`public.url`, Chromium's `org.chromium.source-url`, WebKit's `<base href>`).
- **MacDown's own preview:** the rendered body, including `data-source-line` attributes, Prism's token spans inside `pre` (text only), task-list checkboxes and footnote markup. Footnotes become plain text with the links dropped (non-goal to round-trip).
- **Code editors (VS Code, Xcode, Terminal, JetBrains):** they write HTML or RTF where every run is monospace and colored, with no block structure. Rule: if all visible text is in a monospace font and there are no structural elements (headings, lists, links, tables, emphasis), call `super`. Multi-line text pastes inside a fence are already plain (selection-in-code check).

## Settings

- New preference: General or Editor pane, "Convert formatted text to Markdown when pasting", a `PreferenceSettingKey` case `editorConvertsPastedFormatting` (no original key exists; listed under "Differences from the original" in docs/MACDOWN-PORT.md). Default **on** for new and existing installs (registered as the default, so existing users get it without a stored value).
- Edit ▸ Paste as Markdown (⌥⌘V), available when the setting is off. Strings go through `String(localized:)` and `Localizable.xcstrings`; translations in `Tools/port_translations.json`.

## Phases

### Phase 0: Spike and fixtures

- Collect clipboard captures (all types, raw data) from Safari, Chrome, Google Docs, Word, Pages, TextEdit, Notion, VS Code, Xcode, Terminal and MacDown's preview into `Tests/MacDownKitTests/Resources/Paste/`. Generated sample content only, no real documents (same rule as the corpus).
- Confirm `XMLDocument` with `.documentTidyHTML` parses all of them into usable trees (HTML5 elements, unclosed tags, Word's namespaces). Decide XMLDocument vs SwiftSoup.

### Phase 1: Converter

- `HTMLToMarkdown` with the mapping table, text escaping and the output rules.
- Round-trip tests over the corpus (see "Testing").
- `HTMLToMarkdownTests` for each element, escaping edge cases and nesting.

### Phase 2: Paste

- `paste(_:)`, `readSelection(from:type:)` and the code checks in `EditorTextView`; the HTML and RTF paths.
- The inline "Paste as Plain Text" button.
- Image data paste.
- The setting, the menu item and the help section.

### Phase 3: Source quirks

- Google Docs styles, Word lists, AppKit RTF classes, source-URL resolution, code-editor detection, each with its fixture test.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Code pasted from an editor gets mangled | Monospace-only detection, the selection-in-code check, Paste and Match Style; fixtures from VS Code, Xcode and Terminal |
| Over-escaping makes text ugly (`1\. `, `\*`) | Escape only where the character would change the parse; round-trip tests catch both under- and over-escaping |
| Tidy changes or drops content | Phase 0 decides the parser on real fixtures; compare visible text before and after conversion in tests |
| Huge pastes (a long web page) block the main thread | Measure in Phase 1; if needed, convert pastes over a size threshold off the main actor and insert when done (the converter is `Sendable`) |
| Pasted screenshots make documents very large (a Retina screenshot is often several MB as base64) | Same trade-off as dropped images today; measure editor and preview performance with a large data URI in Phase 2 and revisit (for example, saving images next to the document) if it's a problem |
| The plain-text button gets in the way of typing | It never takes focus and disappears on the next edit |
| Clipboard formats change between app versions | Fixtures make regressions visible; the plain-text fallback always works |

## Testing strategy

- **Round trip over the corpus:** for each document in `Resources/Corpus`, render with `HTMLRenderer`, convert back with `HTMLToMarkdown`, render again, and compare the two HTML bodies (ignoring `data-source-line`). Differences that are expected (extended syntax, footnotes) are listed and reviewed, as with `reviewed-html-diffs.json`.
- **Fixtures:** each captured clipboard has an expected `.md` next to it.
- **Unit tests:** element mapping, escaping, nesting, tables (simple and fallback), whitespace, the list marker and indentation settings.
- **Editor tests:** paste inserts converted text and undoes in one step; Paste and Match Style inserts plain text; paste inside a fence is plain; the setting turns conversion off; the plain-text button replaces the pasted range (and Undo restores it), and is dismissed by typing and Escape; PNG, JPEG and TIFF image data paste as data URIs.
- **Human verification:** before release, a person pastes from each source app in the fixture list (real copies, not the saved captures) into the built app and checks that the result reads and renders like the source, that code pastes unchanged, that the plain-text button works, and that a screenshot pastes and shows in the preview. Problems found become new fixtures.
- **help.md:** a section describing the feature (no live example: a paste can't be rendered), and `HelpDocumentTests` expectations if the section adds rendered content.

## Decisions

Dated, newest first.

**Parser: Foundation's `XMLDocument` with `.documentTidyHTML` (2026-10-21).** The Phase 0 spike parsed every synthetic fixture (Google Docs, Word, MacDown's preview, a browser fragment, VS Code, and AppKit's HTML for TextEdit and Xcode RTF) and kept all visible text. Findings:

- **Google Docs:** Tidy repairs the `<b style="font-weight:normal">` wrapper by copying it, with its style, into every block, so the "normal weight cancels bold" rule still works. A `ul` directly inside a `ul` becomes `<li style="list-style: none"><ul>…</ul></li>`: the converter treats an item holding only a list as a nested list of the previous item.
- **Word:** `o:p` elements and the `<![if !supportLists]>` markers are dropped, the conditional comment in `head` goes with the head, and the list bullet stays as text in `<span style="mso-list:Ignore">`, which the converter skips. `mso-list: lN levelM` survives in `style`.
- **HTML5 elements:** Tidy's HTML 4 grammar drops unknown elements (`nav`, `article`, `section`, `header`, `footer`, `main`, `aside`, `figure`, `figcaption`, `picture`, `source`, `mark`, `details`, `summary`) and keeps their content, so block boundaries are lost (a `figcaption` runs into the preceding image). The converter renames block-level HTML5 elements to `div` and `mark` to `span` before parsing.
- **Text with no tags** parses to a document without a `body`; the converter wraps such input in a `body`.
- **Everything else works:** unclosed tags are closed (`<p>a <b>b<p>c` → two paragraphs), orphan `td`/`li` get a `table`/`ul`, entities are decoded (`&nbsp;` → U+00A0, `&#8617;` → ↩), non-ASCII text is kept, `pre` keeps its newlines and spaces, comments become comment nodes, `<meta charset>` fragments parse, and empty icon-font elements (`<i class="fa …">`) are dropped.

SwiftSoup (a new dependency) isn't needed.

**Plain-text button lifetime and quality check (2026-10-21).**

- The "Paste as Plain Text" button stays until the next edit, a selection change outside the pasted range, scrolling it out of view, Escape or another paste. There's no timeout.
- Paste quality is judged by human verification (see "Testing strategy"), since MacDown has no telemetry.

**Answers to the open questions (2026-10-21).**

- Conversion is **on by default for existing installs too**, not only new ones.
- A converted paste shows an **inline "Paste as Plain Text" button** (like Notion), in addition to Paste and Match Style. See "Inline 'Paste as plain text'".
- Emphasis is always **`*`/`**`**. No new setting.
- **Image data on the clipboard becomes a data URI**, like dropped images, as part of this intent rather than a separate one. See "Image data".

## Open questions

None.

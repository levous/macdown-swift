# PRD: Paste Formatted Text as Markdown

- **Source intent:** [`docs/intents/paste-formatted-text.md`](../intents/paste-formatted-text.md) (Accepted, 2026-10-21)
- **Status:** Draft
- **Date:** 2026-10-21
- **Owner:** Rusty Zarse

---

## 1. Problem Statement

### What problem does this solve?

When someone copies formatted text (a web article, a Google Doc, a Word or Pages document, a Notion page) and pastes it into MacDown, only the plain text arrives. Headings, bold and italic, links, lists, quotes, code and tables are lost, and the writer has to retype all of that structure as Markdown by hand.

The structure is already on the clipboard. Browsers, Google Docs, Notion, Word and MacDown's own preview put HTML there, and Pages, TextEdit and Word put rich text there. MacDown's editor is plain text, so it ignores both. (Intent §Why, §Current state)

### Who experiences this problem?

- **Writers moving existing material into MacDown:** notes, drafts and documents written in Google Docs, Word, Pages or Notion.
- **Writers collecting from the web:** quoting or excerpting articles, documentation and reference pages, with their links.
- **Writers reusing MacDown's own output:** copying from the preview of one document into another.

Writers who paste **screenshots and copied images** get nothing at all today: the editor ignores image data on the clipboard, although dropping an image file already embeds it.

Writers who paste **code** from editors and terminals (VS Code, Xcode, Terminal) are affected the other way: those apps also put colored rich text on the clipboard, and any conversion must leave their code exactly as it is.

### Current state / workaround

- Paste inserts plain text only (Intent §Current state).
- Workarounds: retype the formatting by hand, run the content through an external HTML-to-Markdown converter, or use another editor that converts on paste. Comparable Markdown editors (Obsidian, Typora, Bear) convert on paste, so writers expect it (Intent §Why).

---

## 2. Goals

### Primary goal

Pasting formatted text into MacDown produces clean Markdown that renders like the original, with no retyping.

### Secondary goals

- Pasting from a browser, Google Docs, Word, Pages or MacDown's preview produces idiomatic Markdown that renders like the source (Intent §Goals 1).
- Pasting from code editors and terminals is unchanged: the plain text (Intent §Goals 2).
- A paste undoes in one step (Intent §Goals 3).
- Pasting stays instant for typical content and adds no new dependencies (Intent §Goals 4).
- The conversion is reliable and covered by automated tests over the existing test documents (Intent §Goals 5).
- Pasted Markdown follows the writer's own editing settings, so it looks like the rest of the document (Intent §Principle).
- A converted paste can be swapped for plain text in one click, right where it was pasted (Intent §Decisions).
- Pasted screenshots and copied images are embedded, like dropped image files (Intent §Decisions).

### Non-goals

- Converting dropped or opened `.docx`, `.html` or `.rtf` files, or an Import command.
- "Copy as Markdown" from other apps, or changing what MacDown puts on the clipboard.
- Downloading remote images or embedding them in the document.
- Keeping styling that has no Markdown equivalent (colors, fonts, sizes, alignment, underline) as inline HTML.
- Exact round-tripping of MacDown's extended syntax (math, `[TOC]`, highlight, Mermaid/Graphviz diagrams); best effort only.

---

## 3. Solution / Feature Overview

When the writer pastes into the editor, MacDown looks for formatted content on the clipboard and converts it to Markdown before inserting it. If there's no formatted content, or it comes from a code editor, or the cursor is inside a code block, MacDown pastes plain text as it does today.

- **What converts:** headings, paragraphs and line breaks, bold, italic, strikethrough, inline code, code blocks (keeping their language), links, images, nested bulleted, numbered and task lists, block quotes, horizontal rules and simple tables.
- **What's dropped:** formatting with no Markdown equivalent (colors, fonts, sizes, alignment, underline, superscript/subscript, highlight) is dropped, keeping the text.
- **Complex tables** (merged cells, or block content in cells) are kept as HTML so nothing is lost.
- **Source-aware:** MacDown handles the way specific apps write formatting (Google Docs, Word, Pages/TextEdit, web pages, MacDown's preview) and recognizes code copied from code editors.
- **Images:** a screenshot or copied image on the clipboard is pasted as an embedded image, the same way dropped image files are.
- **Escape hatches:** after a converted paste, a "Paste as Plain Text" button appears next to it and swaps in the plain text with one click. Paste and Match Style (⌥⇧⌘V) always pastes plain text. A setting turns conversion off, and Edit ▸ Paste as Markdown (⌥⌘V) converts on demand while it's off.

The conversion is built into MacDown, in Swift, with no new libraries. A browser-based converter was considered and rejected because it would make paste asynchronous and harder to undo. (Intent §Design)

---

## 4. User Stories

### Writers moving material in

- **P0** As a writer, I want to paste a section of a Google Doc into MacDown so that its headings, emphasis, links and lists arrive as Markdown.
- **P0** As a writer, I want to paste from Word or Pages so that I don't have to retype the document's structure.
- **P1** As a writer, I want nested and numbered lists to keep their nesting and numbering so that outlines survive the move.
- **P1** As a writer, I want simple tables to become Markdown tables so that I can keep editing them as text.
- **P2** As a writer, I want complex tables kept as HTML so that their content isn't lost even if it isn't Markdown.

### Writers collecting from the web

- **P0** As a writer, I want to paste part of a web page so that its text, emphasis and links arrive as Markdown.
- **P1** As a writer, I want links and images with relative addresses to point to the original site so that they still work in my document.
- **P1** As a writer, I want code blocks from documentation pages to become fenced code blocks with their language so that they're highlighted in the preview.

### Writers reusing MacDown output

- **P1** As a writer, I want to copy from MacDown's preview and paste into another document so that I get the Markdown back, including task lists.

### Writers pasting code

- **P0** As a writer, I want code copied from VS Code, Xcode or Terminal to paste exactly as it was copied so that conversion never corrupts it.
- **P0** As a writer, I want pasting inside a code block to insert plain text so that I can paste code into a fence safely.

### Control

- **P0** As a writer, I want Paste and Match Style to paste plain text so that I can always opt out for a single paste.
- **P0** As a writer, I want a converted paste to undo in one step so that I can back out of it easily.
- **P1** As a writer, I want a "Paste as Plain Text" button right after a converted paste so that I can switch to plain text without knowing a shortcut.

### Writers pasting images

- **P1** As a writer, I want to paste a screenshot I just took so that it appears in my document without saving it to a file first.
- **P1** As a writer, I want to paste an image copied from Preview or a browser so that it's embedded like a dropped image.
- **P1** As a writer, I want a setting to turn conversion off so that paste behaves as before if I prefer.
- **P1** As a writer who turned conversion off, I want a Paste as Markdown command so that I can still convert when I choose.
- **P1** As a writer, I want pasted lists to use my chosen list marker and indentation so that pasted content matches the rest of my document.

---

## 5. Requirements

### Functional Requirements

**Paste behavior**

- **FR-1** When conversion is on and the clipboard contains HTML, Paste shall insert the Markdown equivalent of that HTML (Intent §Design › Where it hooks in).
- **FR-2** When the clipboard has no HTML but contains rich text (RTF/RTFD), Paste shall convert the rich text to Markdown the same way.
- **FR-3** When the clipboard contains neither, Paste shall insert the plain text, as today.
- **FR-4** Paste and Match Style (⌥⇧⌘V) shall always insert plain text, whatever the setting.
- **FR-5** When the selection is inside a fenced or indented code block, Paste shall insert plain text.
- **FR-6** When all visible text in the formatted content is monospace and it has no structure (headings, lists, links, tables, emphasis), Paste shall insert plain text (code-editor detection).
- **FR-7** A converted paste shall replace the selection and be undone by a single Undo, and shall mark the document as changed exactly like typed text.
- **FR-8** Text received through Services or dragged from other apps shall be converted under the same rules as Paste.
- **FR-9** When the converted result is a single paragraph, it shall be inserted inline, without added blank lines around it.

**Conversion**

- **FR-10** Headings 1–6 shall become `#`-style headings.
- **FR-11** Bold, italic and strikethrough, whether written as tags or as inline styles, shall become `**…**`, `*…*` and `~~…~~`. These markers are fixed (no setting).
- **FR-12** Inline code and monospace inline text shall become backtick code spans that correctly wrap any backticks they contain.
- **FR-13** Preformatted blocks shall become fenced code blocks, keeping the language when the source names it, with a fence longer than any backtick run inside.
- **FR-14** Links shall become `[text](url "title")`, or `<url>` when the text is the URL. Links to `javascript:` or to in-page anchors of the source page shall keep only their text.
- **FR-15** Images shall become `![alt](src "title")`, keeping the original address.
- **FR-16** Bulleted, numbered and task lists shall keep their nesting, numbered lists their starting number, and task items their checked state. Bulleted lists shall use the writer's list marker setting and indentation setting.
- **FR-17** Block quotes, including nested ones, shall become `>`-prefixed blocks; horizontal rules shall become a rule that can't be misread as a heading under the writer's list marker.
- **FR-18** Tables whose cells hold only inline content and have no merged cells shall become GFM pipe tables, with a header row and column alignment. Other tables shall be kept as HTML.
- **FR-19** Underline, superscript, subscript and highlight shall keep their text only. Scripts, styles, comments and document metadata shall be dropped.
- **FR-20** Text shall have whitespace collapsed as a browser displays it (except in code blocks), entities decoded, and Markdown characters escaped only where they would otherwise change the formatting.
- **FR-21** Output shall have at most one blank line between blocks and no leading blank lines.

**Source-specific handling** (Intent §Design › Source quirks)

- **FR-22** Google Docs content shall convert by its inline styles, including the wrapper that marks everything bold but is styled as normal weight.
- **FR-23** Word content shall drop Word-specific markup and rebuild lists that Word writes as styled paragraphs.
- **FR-24** Pages and TextEdit content shall convert bold, italic, monospace and lists written through style classes.
- **FR-25** Relative link and image addresses copied from a web page shall resolve against the page's address when the browser provides it.
- **FR-26** Content copied from MacDown's preview shall convert back to Markdown, with syntax-highlighting markup reduced to the code text, task checkboxes restored, and footnotes as plain text.

**Settings and menus**

- **FR-27** A preference, "Convert formatted text to Markdown when pasting", shall turn conversion on or off. It shall default to **on** for new and existing installs.
- **FR-28** When conversion is off, Edit ▸ Paste as Markdown (⌥⌘V) shall convert the clipboard under FR-1 – FR-26.
- **FR-29** New UI strings shall be localizable, with existing translation tooling applied.
- **FR-30** The bundled help shall describe the feature.

**Plain-text option and images** (Intent §Design › Inline "Paste as plain text", › Image data)

- **FR-31** After a converted paste, a "Paste as Plain Text" button shall appear just below the pasted text. Clicking it shall replace the pasted text with the clipboard's plain text as one undoable change.
- **FR-32** The button shall disappear on the next edit, a selection change outside the pasted text, scrolling the text out of view, Escape or another paste. It shall never take keyboard focus from the editor, and shall be available to accessibility tools.
- **FR-33** When the clipboard holds only image data, Paste shall insert it as an embedded image (`![](data:…)`), the same markup as dropping an image file. PNG and JPEG are kept as they are; TIFF is converted to PNG.
- **FR-34** Image paste shall work whatever the conversion setting. Images referenced inside pasted HTML shall keep their address and not be fetched.

### Non-Functional Requirements

- **Performance:** a typical paste converts and inserts without noticeable delay, under 50 ms for a long article (Intent §Goals 4). If very large pastes exceed that, conversion may move off the main thread for pastes above a size threshold (Intent §Risks).
- **Reliability:** if conversion can't produce a result, paste falls back to plain text. No content is silently dropped other than formatting without a Markdown equivalent.
- **Safety for code:** no conversion path may alter code copied from code editors or pasted into code blocks.
- **Platform:** macOS 15+, same as the app. No new third-party dependencies and no new C code.
- **Privacy:** clipboard content is processed locally and never leaves the device; remote images are not fetched.
- **Accessibility:** the new setting and menu item have standard labels and keyboard shortcuts.

### Technical Requirements

Summarized; the intent is the engineering source of truth.

- The editor's paste, Services and drag handling read the clipboard in preference order (HTML, then RTF converted to HTML by AppKit, then plain text) and insert through the normal text-change path for undo and autosave (Intent §Design › Where it hooks in).
- A pure, thread-safe converter in MacDownKit takes HTML and options (list marker, indentation, base URL) and returns Markdown. It parses with Foundation's HTML-tidying XML parser; a pure-Swift HTML parser is the fallback if Phase 0 finds tidy inadequate (Intent §Design › The converter, §Phases).
- The full element-to-Markdown mapping is Intent §Design › The converter (table).
- The preference is a new `PreferenceSettingKey` case, registered with a default of on so existing installs get it. It has no equivalent in the original MacDown and is listed under "Differences from the original" in docs/MACDOWN-PORT.md (Intent §Settings).
- Image paste reuses the markup helper used for dropped images; screenshots' TIFF is converted to PNG before encoding.
- Test clipboard captures use generated sample content only, never real documents (Intent §Phases › Phase 0).

---

## 6. Success Metrics

MacDown has no usage telemetry, so metrics are measured through tests, fixtures and feedback.

| Metric | How measured | Target |
|---|---|---|
| Round-trip fidelity | Corpus documents rendered, converted back and rendered again; HTML compared | Zero unreviewed differences |
| Source coverage | Captured clipboard fixtures (Safari, Chrome, Google Docs, Word, Pages, TextEdit, Notion, VS Code, Xcode, Terminal, MacDown preview) matching their expected Markdown | All fixtures pass |
| Code safety | Code-editor fixtures pasting as unchanged plain text | 100% |
| Image paste | PNG, JPEG and TIFF image-data fixtures pasting as embedded images that render in the preview | All pass |
| Conversion time | Timing a long-article fixture | < 50 ms |
| Paste quality | Human verification: before release, a person pastes real copies from each source app into the built app and judges the result against the source (Intent §Testing strategy) | Every source judged acceptable; each problem found becomes a fixture |

### Acceptance Criteria

Product-observable:

- [ ] Pasting a Google Docs selection with headings, bold, italic, links and nested lists produces equivalent Markdown that renders the same structure.
- [ ] Pasting from Word and from Pages produces Markdown headings, emphasis and lists.
- [ ] Pasting part of a web page produces Markdown with working links, including links that were relative on the page.
- [ ] Pasting code from VS Code, Xcode or Terminal inserts exactly the copied text.
- [ ] Pasting inside a fenced code block inserts plain text.
- [ ] Paste and Match Style inserts plain text with conversion on.
- [ ] A converted paste is removed by a single Undo.
- [ ] After a converted paste, the "Paste as Plain Text" button appears; clicking it swaps in the plain text, and Undo brings the Markdown back.
- [ ] Typing or pressing Escape dismisses the button without losing a keystroke.
- [ ] Pasting a screenshot inserts an embedded image that shows in the preview.
- [ ] Conversion is on by default after updating from a version without the feature.
- [ ] Turning the setting off restores plain-text Paste, and Paste as Markdown then converts.
- [ ] Copying from MacDown's preview and pasting produces Markdown that renders like the original, including task lists.
- [ ] Simple tables become pipe tables; tables with merged cells stay as HTML.
- [ ] Pasted bulleted lists use the writer's list marker setting.
- [ ] The help describes the feature.
- [ ] Human verification over every source app has passed for the release build.

Implementation-level: the full engineering checklist (round-trip harness, fixture tests, unit tests for mapping, escaping and nesting, editor tests, help tests) is Intent §Testing strategy, and is inherited here by reference.

---

## 7. Scope

### In Scope

- Converting HTML and rich text on Paste, Services and text drags into the editor.
- The inline "Paste as Plain Text" button after a converted paste.
- Pasting clipboard image data (screenshots, copied images) as embedded images.
- The element mapping above, the code-editor and code-block exceptions, and the source-specific handling for Google Docs, Word, Pages/TextEdit, web pages and MacDown's preview.
- The setting, the Paste as Markdown command, Paste and Match Style as plain text, localization and help.
- Phases: Phase 0 fixtures and parser decision; Phase 1 converter; Phase 2 paste; Phase 3 source quirks (Intent §Phases).

### Out of Scope

- Converting dropped or opened `.docx`, `.html`, `.rtf` files; an Import command.
- Copy as Markdown, or any change to what MacDown writes to the clipboard.
- Downloading or embedding remote images.
- Keeping unsupported styling as inline HTML.
- Exact round-tripping of MacDown's extended syntax and footnotes.

### Future Considerations

- Importing `.docx`/`.html`/`.rtf` files with the same converter (Intent §Non-goals).
- Saving pasted and dropped images as files next to the document instead of embedding them, if embedded screenshots make documents too large (Intent §Risks).

### Resolved

Decided 2026-10-21 (Intent §Decisions):

- Conversion defaults to **on** for existing installs as well as new ones (FR-27).
- A converted paste offers an inline **"Paste as Plain Text"** button, in addition to Paste and Match Style (FR-31, FR-32).
- Emphasis is always **`*`/`**`**, with no setting (FR-11).
- Clipboard image data becomes an **embedded image**, in this feature's scope (FR-33, FR-34).
- The "Paste as Plain Text" button has **no timeout**; it stays until the dismissals in FR-32.
- Paste quality is measured by **human verification** before release (Success Metrics).

### Open Questions

None.

# Ralph Fix Plan: Paste Formatted Text as Markdown

Branch: `feature/markdown-action-selection`

Source: `docs/prd/paste-formatted-text-prd.md` (PRD, Draft 2026-10-21) and
`docs/intents/paste-formatted-text.md` (intent, Accepted; engineering source of truth).
Detailed spec: `.ralph/specs/paste-formatted-text-requirements.md`.
Run with `/goal` (or `/goal all`).

Work top to bottom. `swift test` must pass after every task (including
`HelpDocumentTests`). No new dependencies and no C. Fixtures are generated
sample content only, never real documents. UI strings use `String(localized:)`.

**Verify everything yourself.** Every task is verified with tests and, when it
changes anything visible, in the running app: build a throwaway copy, launch it,
capture its window with `swift Tools/capture-window.swift MacDown <out.png> [title]`,
and look at the screenshot. UI control through System Events was not authorized
as of 2026-10-09; drive the app with temporary environment-gated probes, and if a
task can only be verified by UI control, stop and ask the user to enable it.

## High Priority

### Phase 0: Fixtures and parser decision
- [x] `Tools/capture-pasteboard.swift`: dump every type on `NSPasteboard.general` (raw data per type, plus `manifest.json` listing types, sizes and the source app name passed as an argument) into `Tests/MacDownKitTests/Resources/Paste/<source>/`
- [x] Generated sample source document for captures (`Tests/MacDownKitTests/Resources/Paste/sample.md` + instructions in the tool's header): headings 1–3, bold/italic/strikethrough, inline code, a fenced code block with a language, links (absolute, relative, `#anchor`), an image, nested bulleted and numbered lists (start ≠ 1), a task list, a block quote, a rule, a simple table and a merged-cell table
- [x] HUMAN: copy the sample in Safari, Chrome, Google Docs, Word, Pages, TextEdit and MacDown's preview, and run `capture-pasteboard.swift` for each (2026-10-22; Notion skipped and dropped; VS Code, Xcode and Terminal skipped, covered by the synthetic fixtures and `codeEditors`). The user name in file paths and the Google Doc's ID were replaced with same-length placeholders (`sampleuser00`, `SAMPLE-DOCUMENT-ID…`)
- [x] Synthetic fixtures (hand-authored HTML, so Phases 1–3 aren't blocked on captures): Google Docs wrapper `<b style="font-weight:normal" id="docs-internal-guid-…">` with styled spans; Word `mso-list` paragraphs, `o:p`, `<!--[if …]>`; AppKit RTF export (`p.p1`/`span.s1` + `<style>`, `ul`/`ol`); MacDown preview body (Prism spans, `data-source-line`, task checkboxes, footnotes); browser fragment with relative links, `<picture>`/`srcset`, nav `div`s, and `<base href>`; a VS Code/Xcode all-monospace colored snippet. Each with an expected `.md`
- [x] Fixture loader helper for tests (`Paste/<source>/` → types + expected `.md`); the test target already bundles all of `Resources` (`.copy("Resources")`), so no `Package.swift` change is needed
- [x] Spike: `XMLDocument(xmlString:options: [.documentTidyHTML])` over every fixture: HTML5 elements, unclosed tags, Word namespaces (`o:p`), conditional comments, `<meta charset>` fragments, non-ASCII text and entities. Record per-fixture findings (dropped/changed content, compare visible text) in the intent's "Decisions"
- [x] Record the parser decision (XMLDocument) in the intent "Decisions" and docs/ARCHITECTURE.md "Decisions" if the spike passes; if it doesn't, add an item under "Decisions needed" below and stop (SwiftSoup is a new dependency, so it's the user's call)

### Phase 1: Converter (`Sources/MacDownKit/Document/HTMLToMarkdown.swift`)
- [x] `HTMLToMarkdown` skeleton: `Sendable` struct, `Options` (`listMarker`, `indent`, `baseURL`), `convert(_ html: String) -> String` (plus a single-inline-paragraph flag for FR-9); parse with tidy after renaming HTML5 block elements (`nav`, `article`, `section`, `header`, `footer`, `main`, `aside`, `figure`, `figcaption`, `details`, `summary`) to `div` and `mark` to `span`, wrapping tagless input in a `body` (spike findings), return nil/empty on failure so callers fall back to plain text; recursive visitor with block context (list depth/kind, quote, pre, table) and inline context (bold, italic, strike, code, link)
- [x] Effective styles: before the walk, parse `<style>` blocks (AppKit's `p.pN`/`span.sN` classes) and merge class rules with inline `style` attributes into each element's effective `font-weight`, `font-style`, `text-decoration`, `font-family`; the emphasis, inline-code and code-editor rules read only effective styles (needed by FR-6 for Xcode/Terminal, which write RTF only, and by FR-22/FR-24); tests
- [x] Text handling (FR-20): browser whitespace collapse outside `pre`, entity decoding (`&nbsp;` → space), trailing-space trim; tests
- [x] Escaping (FR-20): `\ * _ [ ] < > ` `` ` `` `~` in text runs; `# > + - =` and `1.`/`1)` only at line start; `|` in table cells; tests for under- and over-escaping (no `1\.` mid-sentence)
- [x] Output rules (FR-21, FR-9): one blank line between blocks, no leading blank lines, trailing newline only after a block, single-paragraph result flagged inline; tests
- [x] Headings and paragraphs (FR-10): `h1`–`h6` → ATX; `p`/text-bearing `div` → paragraphs; `br` → backslash hard break; tests
- [x] Emphasis (FR-11): `strong`/`b`/`font-weight ≥ 600` → `**`; `em`/`i`/`font-style: italic` → `*`; `del`/`s`/`strike`/`line-through` → `~~`; `font-weight: normal` cancels an outer bold; adjacent/nested runs merge cleanly, whitespace moved outside markers; tests
- [x] Inline code (FR-12): `code`, `kbd`, monospace `font-family` → backtick spans sized past embedded backtick runs, space padding when content starts/ends with a backtick; no escaping inside; tests
- [x] Code blocks (FR-13): `pre`/`pre > code` → fenced, language from `language-x`/`lang-x`, fence longer than any internal backtick run, text kept verbatim; tests
- [x] Links (FR-14): `[text](url "title")`, `<url>` when text equals URL, text only for `javascript:` and in-page `#anchor`; URLs with spaces/parens wrapped or encoded; tests
- [x] Images (FR-15, FR-34): `![alt](src "title")`, `src` kept, never fetched; tests
- [x] Lists (FR-16): nested `ul`/`ol`, user marker, `start` number, continuation lines at content column, nesting by `indent` option, loose vs tight items, block content in items; tests for each marker setting and tabs vs spaces
- [x] Task lists (FR-16): `input type=checkbox` in `li` → `[ ]`/`[x]` after the marker; tests
- [x] Block quotes and rules (FR-17): nested `> `; `hr` → `---`, or `***` when the marker is `-`; tests
- [x] Tables (FR-18): pipe table when cells are inline-only and no `rowspan`/`colspan`; header from `thead`/`th` or first row; alignment from `align`/`text-align`; `|` escaped; otherwise raw HTML block; tests for simple and fallback tables
- [x] Dropped elements (FR-19): `sup`/`sub`/`mark`/`u` → text; `script`/`style`/`head`/`title`/comments/`meta`/`link` dropped; test that visible text is preserved
- [x] Round-trip harness (`Tests/MacDownKitTests/PasteRoundTripTests.swift`): for each `Resources/Corpus` document, render with `HTMLRenderer`, convert, render again, compare bodies ignoring `data-source-line` (reuse `HTMLDiffHarness` normalization); unreviewed differences fail; `MACDOWN_DIFF_REPORT` writes a report
- [x] Review round-trip differences; fix real bugs; list expected ones (extended syntax, footnotes) in `Tests/MacDownKitTests/Resources/reviewed-paste-diffs.json`
- [x] Performance test: long-article fixture converts in < 50 ms; record the number. If over, add the off-main-actor path for pastes above a size threshold (NFR Performance)

## Medium Priority

### Phase 2: Paste in the editor
- [x] Preference: `PreferenceSettingKey.editorConvertsPastedFormatting`; `Preferences.editorConvertsPastedFormatting` with save/load; default on via nil-check in `loadDefaultUserDefaults()` (existing installs too, FR-27); tests in `PreferencesTests` (fresh install on, existing install without the key on, stored off stays off)
- [x] `ImageMarkup` helper (`Editor/` or `Utility/`): `![](data:<mime>;base64,…)`; refactor `EditorTextView.performDragOperation` to use it; test
- [x] `PasteboardContent` reader (pure where possible): HTML from `.html`; RTF/RTFD → HTML via `NSAttributedString` + `data(from:documentAttributes: [.documentType: .html])`; image data only (PNG/JPEG kept, TIFF → PNG via `NSBitmapImageRep`); source URL from `public.url`, `org.chromium.source-url`, `<base href>`; tests using a private `NSPasteboard(name:)`
- [x] Code-editor detection (FR-6, uses the Phase 1 effective-styles pass): all visible text monospace and no headings/lists/links/tables/emphasis → plain; tests with the VS Code/Xcode synthetic fixtures
- [x] Code-block check (FR-5): give `EditorTextView` the latest `MarkdownDocumentModel.Block`s from `DocumentController` (alongside the highlight spans); selection inside a `.codeBlock` range → plain; when the model is stale for the current text, fall back to a local fence scan above the caret; tests (fenced, indented, unclosed fence just typed)
- [x] `EditorTextView.paste(_:)` (FR-1 to FR-3, FR-7, FR-9): setting off or in code → `super`; else HTML → RTF → image → `super`; convert with options from `Preferences` (marker, `editorConvertTabs` indent, base URL); insert with `insertText(_:replacementRange:)`, calling `breakUndoCoalescing()` before and after so the paste is its own undo group (not merged with preceding typing); plain-text fallback on failure
- [x] `pasteAsPlainText(_:)` always `super` (FR-4); `@objc pasteAsMarkdown(_:)` converts regardless of the setting (FR-28)
- [x] `readSelection(from:type:)` and readable types so Services and text drags from other apps convert under the same rules (FR-8); image-file drags keep their path
- [x] Editor tests in `LiveDocumentTests` (serialized): type text, paste converted Markdown, Undo once: only the paste is removed and the typed text remains; document marked changed; Paste and Match Style plain; inside a fence plain; setting off → plain, Paste as Markdown converts; single paragraph inline; PNG/JPEG/TIFF data paste as data URIs, regardless of setting
- [x] Edit ▸ Paste as Markdown (⌥⌘V) in `App/MacDownCommands.swift` via `CommandGroup(after: .pasteboard)`, enabled only while the setting is off, dispatched to the editor; verify the shortcut doesn't clash with existing items
- [x] Edit ▸ Paste and Match Style (⌥⇧⌘V): SwiftUI's Edit menu (TextEditingCommands) has no such item, so FR-4's plain-text escape can't be reached from the menu or keyboard; add it next to Paste as Markdown, sending `pasteAsPlainText:` down the responder chain; verify in the running app (found 2026-10-21 while checking the Edit menu)
- [x] `SettingsView`: "Convert formatted text to Markdown when pasting" toggle (Editor pane); verify in the running app with a screenshot
- [x] Inline "Paste as Plain Text" button (FR-31): shown after a converted paste when the result differs from the plain text, positioned just below the end of the pasted range, `refusesFirstResponder`, accessibility label; click replaces the range with the plain text as one undoable change, its own undo group separate from the paste (Undo restores the Markdown)
- [x] Button dismissal (FR-32): next edit, selection change outside the range, range scrolled out of view, Escape (via `cancelOperation:`, otherwise normal behavior), another paste; pasted range and plain text released on dismissal; no timeout
- [x] Button tests: appears after converted paste only; click swaps and Undo restores; typing dismisses without losing the keystroke; Escape dismisses; verify placement in the running app with a screenshot
- [x] Large image paste: measure editor and preview responsiveness with a multi-MB data URI (Retina screenshot size); record numbers in the intent "Decisions"
- [x] Localization (FR-29): add "Convert formatted text to Markdown when pasting", "Paste as Markdown", "Paste as Plain Text" to `App/Localizable.xcstrings`; run `python3 Tools/import_localizations.py <original macdown>` if available; add translations to `Tools/port_translations.json` where possible
- [x] `Resources/help.md` (FR-30): section on pasting formatted text (what converts, what's dropped, code safety, setting, Paste as Markdown, Paste and Match Style, plain-text button, image paste); update `HelpDocumentTests` expectations if needed
- [x] Docs: `docs/MACDOWN-PORT.md` "Differences from the original" (paste conversion, new setting, image paste); `docs/ARCHITECTURE.md` (code layout, "Editor and highlighting" paste path, Tests section for the round-trip harness, dated "Decisions" entry); `CLAUDE.md` Editor section if the paste path warrants a line

### Phase 3: Source quirks (each with its fixture test)
- [x] Google Docs (FR-22): wrapper bold cancelled by `font-weight:normal`; styles on spans for bold/italic/strike/monospace; real `h*` headings; nested lists
- [x] Word HTML (FR-23): drop `mso-*`, conditional comments, `o:p`; rebuild nested bulleted/numbered lists from `mso-list: lN levelM` paragraphs, dropping the hidden bullet span
- [x] Pages / TextEdit via RTF (FR-24): fixture tests over the Phase 1 effective-styles pass (class-based bold, italic, monospace); AppKit `ul`/`ol` lists for `NSTextList`
- [x] Web pages (FR-25): resolve relative `href`/`src` against the source URL (`public.url`, `org.chromium.source-url`, `<base href>`); `<picture>`/`srcset` → `img src`; skip icon-font glyphs; in-page `#anchor` links text only
- [x] MacDown preview (FR-26): Prism token spans → code text, language kept from the `pre`/`code` class; task checkboxes restored; footnote markup → plain text without links, and the `rev="footnote"` back-link (↩) dropped entirely, as the fixture's `expected.md` has it; `data-source-line` ignored; test by rendering `help.md` sections and converting back
- [x] Code editors (FR-6): fixture tests for VS Code, Xcode, Terminal (and JetBrains if captured) paste exactly the plain text
- [x] Real captures: `expected.md` for all seven (what the clipboard holds, written as Markdown); `google-docs` passes and is in `PasteFixtureConversionTests.fixture`. The tasks below make the others pass; add each fixture to that test's arguments when it does
- [x] Table header cells (preview, Safari, Chrome): browsers copy `th` with an inline `font-weight: bold`, so headers come out as `| **Name** |` and `<th><strong>Region</strong></th>`. Ignore bold on `th` (and inside it), since header cells are bold already; bold `td`s (Google Docs, Word, Pages, TextEdit) keep it. Makes `chrome` pass
- [ ] In-page links from Safari and MacDown's preview: WebKit writes `#lists` as an absolute URL (`file:///…/sample.html#lists`, `x-macdown-preview://local/…/sample.md#lists`), so the "in-page `#anchor` → text only" rule misses it. Treat a link as in-page when it's the source page's URL plus a fragment. Neither puts `public.url` or `org.chromium.source-url` on the clipboard; check whether the page URL can come from `com.apple.webarchive` (`WebMainResource` → `WebResourceURL`) or the HTML's `<base href>`. Makes `safari` pass
- [ ] Links copied from MacDown's preview use the preview's internal scheme (`x-macdown-preview://local/<path>`); map them back to `file:///<path>` (the inverse of `PreviewURL`) before writing Markdown, as Safari's copy of the exported page has them. With the in-page task, makes `macdown-preview` pass
- [ ] Word for the web lists: each item is its own `ul`/`ol` in a `ListContainerWrapper`, with `data-listid`, `data-aria-level` and `aria-posinset` on the `li`. Join consecutive items with the same list ID into one list, nested by `data-aria-level`, keeping `ol start`; different IDs stay separate lists (alternating `.`/`)` as now). Desktop Word's `mso-list` handling is separate and unchanged. With the heading task, makes `word` pass
- [ ] RTF numbered lists (Pages, TextEdit): the RTF has the start number (`\levelstartat3`) and a numbered list nested in a numbered list (`\ilvl1`), but the converted Markdown restarts at 1 and un-nests the sub-steps. Check whether AppKit's RTF → HTML keeps `NSTextList.startingItemNumber` and the nesting (bulleted nesting already works) and fix the HTML walk or read the lists from the attributed string. With the heading task, makes `pages` and `textedit` pass
- [ ] Headings from font size (RTF from Pages/TextEdit, Word for the web), where the source has no heading markup. The headings in the captures are **not bold**, only larger: RTF 22.5/18.5/17.6pt Helvetica-Light over body text in both 16pt and 12pt; Word 16.5/13.5/13pt over 12pt. So: the body size is the size covering the most characters of paragraph text; a paragraph becomes a heading when all its text is at one size clearly larger than the body (about 1.08× or more), it's a single short line, and it isn't in a list, table or quote; levels come from ranking the distinct heading sizes in the paste, largest = `#`, at most `###`. Pages that already have `h1`–`h6` (browsers, Google Docs, desktop Word) are unaffected. Tests: the three captures (expected `#`/`##`/`###` already in their `expected.md`), a large-but-long paragraph and a bold short line at body size stay paragraphs

## Low Priority

### Release
- [x] Gate: `swift build`, `swift test`, `xcodegen generate` + `xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Debug build` all pass
- [ ] HUMAN: human verification on the built app: paste real copies from Safari, Chrome, Google Docs, Word, Pages, TextEdit, VS Code, Xcode, Terminal and MacDown's preview; check rendering against the source, code unchanged, plain-text button, screenshot paste shows in the preview. Each problem found becomes a new fixture task above
- [ ] HUMAN: release notes mention paste conversion (on by default for existing installs), the setting, Paste as Markdown, and image paste

### Decisions needed
- [x] Infer headings from font size? RTF (Pages, TextEdit) and Word for the web have no heading markup, only larger text, so headings paste as plain paragraphs. Inferring them recovers headings but can turn a short emphasized paragraph into one. **Decided 2026-10-22: yes** (task "Headings from font size" in Phase 3; the `word`, `pages` and `textedit` `expected.md` files have the headings)

### Future (out of scope; do not implement)
- Importing dropped/opened `.docx`/`.html`/`.rtf` files with the same converter
- Saving pasted and dropped images as files next to the document instead of embedding them
- Copy as Markdown; keeping unsupported styling as inline HTML; exact round-tripping of extended syntax and footnotes

## Completed
- [x] Project initialization
- [x] Intent accepted and PRD drafted (2026-10-21, commit 94a525c)

## Notes
- Principle: paste what the user sees, written the way they would have typed it. Drop formatting with no Markdown equivalent; never approximate with inline HTML.
- Decided 2026-10-21: conversion on by default for existing installs too; emphasis always `*`/`**` (no setting); inline "Paste as Plain Text" button with no timeout; image data on the clipboard becomes a data URI, independent of the setting; quality judged by human verification.
- Rejected: a browser-based (JS) converter, because it makes paste asynchronous and harder to undo.
- The preference has no original MacDown key; list it under "Differences from the original".
- Defaults that must reach existing installs go in `Preferences.loadDefaultUserDefaults()` (nil-check), not `loadDefaultPreferences()` (first launch only).
- The code-block check reads `MarkdownDocumentModel.Block` (`.codeBlock`, UTF-16 `range`); the model can be one parse behind the text.
- Tests that touch `Preferences.shared` or the general pasteboard go in the serialized `LiveDocumentTests` suite; prefer private named pasteboards in unit tests.
- The migration plan's remaining (blocked) items are in `.ralph/swift-markdown-fix_plan.md`.
- `.ralph/` is gitignored; commit this plan file with `git add -f`.
- Real captures (2026-10-22): the `word` capture is Word for the web (Office Online markup, no `mso-*`), not desktop Word. Google Docs drops strikethrough, the relative and in-page links, task checkboxes and quotes before copying; Word for the web, Pages and TextEdit drop the relative and in-page links, quotes, rule and image (Word also nests the sub-steps as a separate list); none of that is a converter bug. WebKit copies text with CSS `text-transform` applied, so the preview and Safari captures say "Quotes And Rules".

# Migrate Markdown parsing to swift-markdown

- **Status:** Accepted (decisions recorded below)
- **Date:** 2026-10-09
- **Scope:** Replace both Markdown parsers, hoedown (`Sources/CHoedown`, preview and export) and PEG Markdown Highlight (`Sources/CPegMarkdown`, editor highlighting), with Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) (built on cmark-gfm). Align Markdown formatting, settings and editing defaults with standard conventions (see "Principle").

## Principle

**The most expected, standard behavior, with the greatest feature support.**

- **Standard Markdown is always on.** CommonMark and GitHub Flavored Markdown (GFM) render wherever Markdown is displayed: preview, print, PDF and HTML export, Copy HTML. There is no setting to turn standard syntax off.
- **Extended, non-standard features are opt-in settings, off by default:** `==highlight==`, autolinks, smart punctuation, `^superscript`, `[TOC]`, hard wrap, math, Graphviz. They're kept (natively or with our own small pass) rather than dropped wherever that's practical.
- **Editing follows Markdown conventions** (CommonMark/GitHub style, markdownlint defaults), except for those extended features.
- Where two features do the same job, keep one: `"quote"` → `<q>` is dropped in favor of smart punctuation.

## Why

- **Two parsers that disagree.** The editor colors text with one grammar and the preview renders with another, so they disagree at the edges (what counts as emphasis, a list, a code block).
- **hoedown is unmaintained and predates CommonMark.** Its last release, 3.0.7, is from 2016. Users' expectations now come from CommonMark and GitHub (GFM).
- **Scroll sync depends on mimicking hoedown.** `ScrollAnchors` (`Document/ScrollSync.swift`) re-implements hoedown's block rules in Swift so the editor's anchors line up with the preview's. Every mismatch is a drift bug (for example the `help.md` code-fence bug). cmark reports source positions, so the preview can be matched to the editor by real source lines instead.
- **Less vendored C.** This removes two C targets and the generated `pmh_parser.c`.
- **Settings that hide standard behavior.** Today standard syntax such as task lists, strikethrough and front matter is off by default, behind per-syntax toggles.

## Goals

1. One parse of the document feeds the editor highlighting, the preview, export and scroll sync.
2. Rendering follows CommonMark and GFM, always on; extended features are opt-in settings, off by default (see "Principle").
3. Editing defaults follow Markdown conventions for new installs.
4. Scroll sync aligns by source position, not heuristics.
5. No user-visible regressions in the bundled `help.md` or the generated test corpus, other than intended CommonMark differences and removed syntax, which are documented.

## Non-goals

- Byte-identical HTML with the original MacDown. This goal (CLAUDE.md, README) is dropped and replaced by "CommonMark/GFM output, with differences listed in docs/MACDOWN-PORT.md".
- New Markdown syntax beyond what MacDown supports today.
- Changing existing users' editing settings. New defaults apply to new installs only.
- Changing the editor theme file format (`.style`). Existing and user themes must keep working.

## Current state

| Concern | Today | Code |
|---|---|---|
| Preview/export HTML | hoedown, with MacDown patches for code blocks and task lists, a second pass for `[TOC]`, and a smartypants post-pass | `Document/MarkdownParser.swift`, `Document/Renderer.swift` (flag mapping), `Sources/CHoedown` |
| Markdown settings | Settings ▸ Markdown: Table, Fenced code block, Footnote, Intra-word emphasis, Strikethrough, Quote, Highlight, Superscript, Autolink, Smartypants, each a hoedown flag (Underline was removed on 2026-10-09) | `Preferences/SettingsView.swift`, `Preferences/Preferences.swift`, `Renderer.swift` |
| Rendering settings | Settings ▸ Rendering: task lists, front matter, `[TOC]`, hard wrap and math are off by default; code highlighting and Mermaid on; Graphviz off | same |
| Editing defaults | List marker `*`; no newline at end of file; tabs (not spaces) | `Preferences.swift` (`loadDefaultPreferences`) |
| Prism languages | Collected through the code-block patch callback (`languageAddition`) | `MarkdownParser.swift` |
| Front matter | Our own regex plus Yams, rendered as a table before parsing | `Utility/String+Lookup.swift`, `MarkdownParser.swift` |
| Editor highlighting | PEG Markdown Highlight: element ranges are re-parsed in a background task after edits and styled for the visible range | `Editor/MarkdownHighlighter.swift`, `Sources/CPegMarkdown` |
| Themes | `.style` files with sections named after PEG element types (`H1`…`H6`, `EMPH`, `STRONG`, `HRULE`, `LIST_BULLET`, `LIST_ENUMERATOR`, `LINK`, `AUTO_LINK_URL`, `AUTO_LINK_EMAIL`, `REFERENCE`, `IMAGE`, `CODE`, `VERBATIM`, `HTML_ENTITY`, `COMMENT`, `BLOCKQUOTE`, …), parsed by `pmh_styleparser.c` | `Resources/Themes` (15 themes) |
| Scroll sync anchors | Swift copy of hoedown's block rules (headers, setext underlines, fences, image-only paragraphs) | `Document/ScrollSync.swift` |
| Tests | `RendererTests` (10 tests), `HighlighterTests`, `ScrollAnchorsTests`, the help.md anchor test | `Tests/MacDownKitTests` |

## Markdown formatting after the migration

### Always on (standard)

| Syntax | swift-markdown / cmark-gfm | Plan |
|---|---|---|
| CommonMark: emphasis, strong, headings, lists, links, `<url>` autolinks, images, code, block quotes, rules, inline and block HTML | Built in | `_x_`/`*x*` italic, `__x__`/`**x**` bold; intra-word emphasis follows CommonMark (`*` works inside words, `_` doesn't) |
| Tables, fenced code, strikethrough, task lists | GFM, built in | Always on. Task lists render with MacDown's current markup and classes |
| Footnotes | cmark-gfm has footnotes, but swift-markdown doesn't parse them (F1) | Always on. How they render is open question 1 |
| Front matter (a valid YAML block at the very top) | Not supported | Always rendered as a table, as GitHub does. Keep the current Yams step; blank the block before parsing so positions stay correct. A leading `---` that isn't valid YAML stays ordinary Markdown |
| Underline | No Markdown syntax | HTML `<u>…</u>` (the Underline toolbar button and ⌘U insert it). Done 2026-10-09 |
| Fenced-code syntax highlighting (Prism), Mermaid | Renderer + page scripts | On by default as today (settings kept for performance); GitHub renders both |

### Opt-in (extended), off by default

Each keeps its current user defaults key, so existing users keep their choice.

| Feature | Where | Plan |
|---|---|---|
| `==highlight==` | Settings ▸ Markdown (`extensionHighlight`) | Our own scan; not native (F4, see "Highlight and superscript") |
| `^superscript` | Settings ▸ Markdown (`extensionSuperscript`) | Our own scan; not native (F4, see "Highlight and superscript"); `x^2` and `x^(text)` as today |
| Autolinks (bare URLs and email addresses) | Settings ▸ Markdown (`extensionAutolink`) | GFM, built in; **check whether swift-markdown can turn it off**. If not, the renderer shows autolinked URLs as plain text when off. `<url>` links always work |
| Smart punctuation (curly quotes, dashes, ellipses) | Settings ▸ Markdown (`extensionSmartyPants`, labeled "Smart punctuation") | Native: cmark's smart punctuation, turned off with `.disableSmartOpts` when the setting is off (F3); never in code |
| Math (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) | Settings ▸ Rendering (`htmlMathJax`, `htmlMathJaxInlineDollar`) | Off by default as today (MathJax loads from the internet). Protect math before parsing (see "Math") |
| `[TOC]` | Settings ▸ Rendering (`htmlRendersTOC`) | Build from `Heading` nodes; replace a paragraph containing only `[TOC]` |
| Hard wrap | Settings ▸ Rendering (`htmlHardWrap`) | Soft breaks render as `<br>` |
| Graphviz | Settings ▸ Rendering (`htmlGraphviz`) | Unchanged |

Presentation settings (code-block line numbers and accessory, styles, themes) are unchanged. The renderer emits today's code-block markup: `<div><pre class="line-numbers" data-information><code class="language-…">`.

### Dropped

| Feature | Why | Afterwards |
|---|---|---|
| `"quote"` → `<q>` (`extensionQuote`) | Non-standard, and duplicates smart punctuation (which conflicted with it) | `"text"` stays as typed; curly with Smart punctuation on |

## Settings afterwards

The removed settings' user defaults keys are left in place, unused, so a downgrade still finds them.

| Setting | Default today | Afterwards |
|---|---|---|
| **Settings ▸ Markdown** | | Shows Highlight, Superscript, Autolink, Smart punctuation |
| Highlight, Superscript, Autolink | Off | **Kept**, off by default |
| Smartypants | Off | **Kept** as "Smart punctuation", off by default |
| Table, Fenced code block, Footnote | On | Removed; always on |
| Strikethrough | Off | Removed; always on |
| Intra-word emphasis | On | Removed; CommonMark's rule |
| Quote | Off | Removed; dropped |
| Underline | Off | Already removed (2026-10-09); `<u>…</u>` HTML |
| **Settings ▸ Rendering** | | |
| Task list syntax | Off | Removed; always on |
| Detect Jekyll front-matter | Off | Removed; always on |
| TeX-like math, `$` inline, `[TOC]`, hard wrap, Graphviz | Off | Kept, off by default |
| Code syntax highlighting, Mermaid | On | Kept, on by default |

### Editing defaults (new installs only)

| Setting | Today | New default | Convention |
|---|---|---|---|
| List marker (`editorUnorderedListMarkerType`) | `*` | `-` | GitHub docs, markdownlint MD004 |
| Ensure newline at end of file on save (`editorEnsuresNewlineAtEndOfFile`) | Off | On | POSIX text files, markdownlint MD047 |
| Insert spaces instead of tabs (`editorConvertTabs`) | Off | On | markdownlint MD010 |

Bold `**`, italic `*`, strikethrough `~~` and fenced code already follow convention; underline is `<u>…</u>`. The Highlight toolbar/menu item inserts `==…==`, which only renders with Highlight on. These go in `loadDefaultPreferences`, so existing users keep their settings.

**Checked 2026-10-09: the inline formatters work today.** With each toggle on (hoedown, current app): `==text==` renders `<mark>`, `x^2` / `x^(text)` render `<sup>`, `_text_` rendered `<u>` (before Underline was removed), `"text"` renders `<q>`, including nested inside other formatting (`**==text==**`, `==*text* more==`), and the default GitHub2 preview style shows each visibly. Why they can look broken: most are off by default, and the editor's highlighter doesn't color them (no PEG types), so only the preview shows them. Making strikethrough, task lists and front matter always on is visible for users who had them off, and dropping quote removes a working feature; both belong in the release notes.

Places that change:

- `Preferences/SettingsView.swift`: `MarkdownSettingsView` keeps Highlight, Superscript, Autolink and Smart punctuation; the Rendering pane loses Task list syntax and Detect Jekyll front-matter.
- `Preferences.swift`: the removed properties go; `loadDefaultPreferences` gets the new editing defaults. `Renderer.swift`: `extensionFlags` / `rendererFlags` always set the always-on features (hoedown), then only the opt-in ones remain (swift-markdown).
- The editor highlighter's footnote extension, which follows the Footnote setting today (backwards; see "Decisions").
- The bundled help (`Resources/help.md`): "The Markdown Preference Pane" section, the "Inline Formatting" table and the Quote footnote, the Smartypants paragraph, and the Rendering pane section (task lists, front matter), rewritten for what's always available and what's opt-in.
- docs/MACDOWN-PORT.md "Differences from the original".

## Target architecture

```
MarkdownDocumentModel (new, value type, Sendable)
  ├─ source: String (+ LineIndex: UTF-8 line/column ↔ UTF-16 offset)
  ├─ protected: math spans and front matter blanked with same-length filler
  └─ document: Markdown.Document   (swift-markdown, parsed once per edit)
        │
        ├─ HTMLRenderer: MarkupVisitor          → preview/export body HTML,
        │     data-source-line on blocks, Prism languages, TOC, math,
        │     highlight, superscript, smart punctuation, autolink handling
        ├─ HighlightMapper: MarkupWalker        → [HighlightSpan] keyed by
        │     theme element type (H1…, EMPH, VERBATIM, …) plus source scans
        │     for REFERENCE, HTML_ENTITY, list markers, ==highlight==, ^sup
        └─ SourceAnchors                        → scroll sync anchors from
              block source positions (replaces ScrollAnchors' scanner)
```

- **One parse per edit, off the main thread.** Today the renderer and the highlighter each parse; afterwards one background task builds a single model that both consume. The renderer's background parse with its generation counter (`Renderer.parse`) is reused.
- **Few options.** The parse always enables GFM, footnotes and front matter; `ParseSettings` keeps only the opt-in features (highlight, superscript, autolink, smart punctuation, math, `[TOC]`, hard wrap).
- **`LineIndex`.** swift-markdown reports `SourceLocation(line:column:)` with **UTF-8** columns. A per-document line table converts these to UTF-16 `NSRange`s for the editor, the same problem `HighlightElements.parse` solves today for PEG offsets.
- **Theme parser.** Port `pmh_styleparser.c` to Swift (`ThemeStyleParser`). It's a small line-based format. Keep element names unchanged so all 15 bundled themes and users' themes still work.
- **No new C.** swift-markdown is a SwiftPM dependency that brings Apple's `swift-cmark`.

### Highlight and superscript

`==text==` and `^text` stay, each behind its setting (off by default). swift-markdown has no native support (F4), so handle them ourselves without changing the parser:

- **Renderer:** with the setting on, when visiting a `Text` node, split it on `==…==` pairs (emit `<mark>`) or `^word` / `^(text)` (emit `<sup>`).
- **Highlighter:** with the setting on, the same scanner yields spans of a new highlight type, so the editor can color them too (themes without a style for them don't).
- **Limit:** the markers must sit within one run of plain text, so `==*emph* inside==` doesn't highlight (hoedown did). The corpus diff shows whether that matters.

### Math

Emphasis is parsed before we see text, so math must be protected **before** parsing:

1. Find math spans in the source (`$$…$$`, `\[…\]`, `\(…\)`, and `$…$` when inline dollars are on), skipping code spans and fenced blocks.
2. Replace each span's content with filler of the **same UTF-8 length** that has no Markdown meaning (for example `x`), so every source position stays valid.
3. When rendering, emit the original span text from the source by range, unescaped, for MathJax. The highlighter can style math spans as a new type (themes without a style for it don't color it).

Front matter uses the same trick: blank it to same-length filler instead of cutting it off, so line numbers match the editor.

## Phases

Each phase from 0 on lands behind a hidden setting (`markdownEngine` = `hoedown` | `swiftMarkdown`, default `hoedown`) until Phase 5, so both engines can be compared side by side in the app.

### Early step: settings and defaults on hoedown (optional, can ship before Phase 0)
- Settings ▸ Markdown keeps Highlight, Superscript, Autolink and Smartypants (relabeled "Smart punctuation"), off by default; the other Markdown toggles go. hoedown always runs with tables, fenced code, footnotes, strikethrough and intra-word emphasis on; Quote is off (dropped).
- Settings ▸ Rendering loses Task list syntax and Detect Jekyll front-matter; both always on.
- The editor highlighter always enables footnotes.
- New editing defaults for new installs (list marker `-`, newline at end of file, spaces for tabs).
- Rewrite the affected help sections; docs/MACDOWN-PORT.md note.
- Ships the principle now and makes the later engine switch a pure parser change.

### Phase 0: Spike and parity harness
- Add swift-markdown to `Package.swift`, pinned to an exact version.
- Answer the remaining unknowns: footnotes; smart punctuation, highlight and superscript (each decides between native and our own pass); whether GFM autolinks can be turned off at parse time (otherwise the renderer un-links them); whether source positions are available on every block node; and Swift 6 strict-concurrency compatibility. Record the answers in "Decisions".
- Build a **corpus**: `help.md` first (it has a live example of every feature and setting, and `HelpDocumentTests` already checks rendering, editor highlighting and the real preview against it), then **generated** fixtures in `Tests/MacDownKitTests/Resources/Corpus/`: purpose-written Markdown per feature area with edge cases, an image-heavy document, and a 10k-line document generated in the test. Never real user documents or other docs.
- Write two diff tools (as tests or a script under `Tools/`):
  - HTML diff, hoedown vs swift-markdown with the same formatting (the always-on set, and each opt-in feature off and on), after normalizing whitespace and attribute order;
  - highlight-span diff, PEG vs swift-markdown, per element type.
- **Exit:** unknowns answered in "Decisions"; diffs run in CI. Differences caused by dropped syntax (quote) are expected and listed once, not reviewed per document.

### Phase 1: Shared model
- `MarkdownDocumentModel`, `LineIndex` (UTF-8 ↔ UTF-16), and the protection pass for math and front matter.
- **Tests:** `LineIndex` with emoji, surrogate pairs and CRLF; protection keeps byte offsets; protected spans survive emphasis-heavy content.

### Phase 2: Highlighter
- `HighlightMapper` from the tree, plus source scans for `REFERENCE` definitions, `HTML_ENTITY`, list markers, `<!-- -->` comments and (with their settings on) `==highlight==` and `^superscript`.
- `ThemeStyleParser` (Swift port); compare its parsed styles with `pmh_styleparser.c`'s for all 15 themes.
- `MarkdownHighlighter` takes spans from the model instead of `pmh_markdown_to_elements`.
- **Exit:** the highlight-span diff on the corpus shows only intended differences; `HighlighterTests` ported; highlighting stays smooth on a large document (measure re-parse time against PEG on a 10k-line file).

### Phase 3: Renderer
- `HTMLRenderer` (a `MarkupVisitor`):
  - core blocks and inlines;
  - code-block markup and the Prism language list (alias mapping moves from `languageAddition`);
  - always on: tables, task lists, footnotes, strikethrough, front matter table;
  - opt-in: highlight, superscript, autolinks, smart punctuation, math pass-through, `[TOC]`, hard wrap;
  - `data-source-line` on block elements, preview only (export stays clean, like today's body markers).
- `PageBuilder` is unchanged apart from where `ParseResult` comes from.
- **Exit:** `RendererTests` pass on both engines (expectations updated only where CommonMark differs, each one noted); HTML diff on the corpus reviewed; Mermaid, Graphviz, MathJax and Prism render in the app; exports and PDF checked.

### Phase 4: Scroll sync by source position
- The preview reports block positions as `[source line, y]` from `data-source-line`; the editor maps line to y through `LineIndex` and its layout.
- Replace `ScrollAnchors.scan` and the kind-matching logic with a source-line map. Keep `ScrollGeometry` and `ScrollMap`; only the anchor source changes.
- **Exit:** the scroll sync tests (`ScrollSyncTests`) pass with source-line anchors; `help.md` and image-heavy documents stay aligned with unequal pane widths, in both scroll directions.

### Phase 5: Switch and remove
- Default `markdownEngine` to `swiftMarkdown`, ship a release, keep `hoedown` reachable through the hidden setting for one release.
- Then remove `Sources/CHoedown`, `Sources/CPegMarkdown`, the hidden setting, `ScrollAnchors`' scanner, and the hoedown and PEG licenses from `Licenses/` (add swift-markdown and cmark's).
- If the early step didn't ship: apply "Settings afterwards" and the editing defaults.
- Update docs/MACDOWN-PORT.md ("Differences from the original" lists CommonMark output, always-on features, opt-in settings and dropped syntax; "Regenerating the highlighter parser" removed; layout table), CLAUDE.md (render pipeline, Editor, Tests, the byte-identical output goal), and the bundled `help.md`.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| CommonMark changes how existing documents render (emphasis, lists, HTML blocks) | Corpus diff reviewed in Phase 3; README lists the differences; hidden fallback for one release |
| Always-on standard features change documents for users who had them off: `~~text~~` strikes through, `- [ ]` renders checkboxes, a leading YAML block renders as a table | Intended (Principle). Release notes call it out; code spans and blocks are never affected; `\` escapes a marker; invalid YAML at the top stays ordinary Markdown |
| swift-markdown doesn't support smart punctuation, highlight or superscript natively | Our own pass over text nodes (never in code), behind each setting |
| GFM autolinks can't be turned off at parse time | The renderer un-links autolink-extension links when Autolink is off; `<url>` links (CommonMark) still work |
| swift-markdown doesn't expose footnotes (confirmed, F1) | Open question 1: a source scan, keeping hoedown for footnotes (and not removing it), or using cmark-gfm directly |
| Users relied on `"quote"` → `<q>` | Listed in docs/MACDOWN-PORT.md and the release notes; the text still shows; Smart punctuation gives curly quotes |
| Our highlight/superscript scan differs from hoedown's | Plain text only (not around other formatting, like `==*a* b==`); listed in docs/MACDOWN-PORT.md; corpus diff shows real use |
| Math protection mishandles edge cases (escaped `\$`, `$` in code, currency) | Dedicated tests from MathJax's own delimiter rules; math and inline `$` stay opt-in |
| New editing defaults surprise users | New installs only; existing users keep their settings |
| Highlighting performance on large files | Measured in Phase 2; the highlighter already debounces and only styles the visible range |
| swift-markdown API changes (pre-1.0) | Pin an exact version; wrap it behind `MarkdownDocumentModel` so only one file touches its API |
| Themes rely on PEG types that have no AST equivalent | Source scans for `REFERENCE`, `HTML_ENTITY` and list markers; span diff per element type in Phase 2 |
| Scroll sync regresses during the switch | Phase 4 only after the renderer is stable; existing scroll tests must pass unchanged |

## Testing strategy

- **`help.md` is the primary fixture.** `HelpDocumentTests` must pass on both engines; its expectations change only where a decision in this plan changes behavior. Update `help.md` in the same phase that changes a feature (the early step and Phase 5 rewrite its settings sections).
- **Golden corpus diffs** (HTML and highlight spans) run in CI on both engines until Phase 5.
- **Unit tests:** `LineIndex`, the protection pass, math pass-through, TOC, code-block markup, task lists, front matter (valid and invalid YAML), footnotes; that standard formatting renders with default (empty) user defaults; each opt-in feature off (plain text) and on; that `"quote"` renders as typed; new editing defaults on a fresh install and unchanged for an existing one.
- **Integration tests** in the serialized `LiveDocumentTests` group: the preview renders with the new engine; Mermaid, MathJax and Prism still run; scroll sync with source-line anchors.
- **In-app verification** for every phase: launch a throwaway build with `help.md` and corpus documents, capture its window (`Tools/capture-window.swift`) and check the screenshots; check print and HTML/PDF export output.

## Decisions

1. **Byte-identical output with the original MacDown is dropped.** Output is CommonMark/GFM, with differences listed in docs/MACDOWN-PORT.md.
2. **Principle:** the most expected, standard behavior with the greatest feature support. Standard Markdown is always on; extended features are opt-in settings, off by default; editing follows conventions.
3. **Always on:** CommonMark, GFM tables, fenced code, strikethrough and task lists, footnotes, and front matter (rendered as a table). Intra-word emphasis follows CommonMark. Code highlighting and Mermaid stay on by default.
4. **Underline is HTML `<u>…</u>`** (the Underline setting was removed on 2026-10-09); underscores follow standard Markdown (`_x_` italic, `__x__` bold).
5. **Opt-in settings, off by default:** Highlight, Superscript, Autolink, Smart punctuation (Settings ▸ Markdown); math and inline `$`, `[TOC]`, hard wrap, Graphviz (Settings ▸ Rendering). Smart punctuation is cmark's own (on unless `.disableSmartOpts` is passed, F3); highlight, superscript and bare-URL autolinks are our own pass over text runs, since swift-markdown parses none of them (F2, F4).
6. **`"quote"` → `<q>` is dropped;** Smart punctuation covers typographic quotes.
7. **Math stays opt-in, off by default** (MathJax needs a network connection).
8. **Editing defaults follow conventions for new installs:** list marker `-`, newline at end of file on, spaces instead of tabs. Existing users keep their settings.
9. **Footnotes have no setting.** The "backwards" footnote-highlighting flag in `DocumentController` turned out to be harmless: PEG Markdown Highlight defines a `NOTE` type but never emits it, so footnotes aren't colored in the editor with either flag value (checked 2026-10-09). The new highlighter colors footnotes (a `NOTE` span type).

10. **The parser is cmark-gfm, used directly** (decided 2026-10-09, after finding F8). swift-cmark's `cmark-gfm` and `cmark-gfm-extensions` products, pinned exactly, parse once per edit with source positions, footnotes (`CMARK_OPT_FOOTNOTES`), the `table`, `strikethrough` and `tasklist` extensions always, `autolink` only with the Autolink setting on, and `CMARK_OPT_SMART` only with Smart punctuation on. Our model, highlighter and renderer walk cmark's C tree inside the parse task; swift-markdown's Swift tree is no longer used and the dependency goes. This resolves open questions 1 (footnotes are native) and 2 (cmark-gfm parses and walks 10,000 lines in 4.5 ms, against PEG's 20). Documents keep the "swift-markdown migration" name.

### Phase 0 findings

Answers from the spikes in `Tests/MacDownKitTests/SwiftMarkdownSpikeTests.swift` (swift-markdown 0.9.0, swift-cmark 0.9.0):

- **F1. Footnotes are not exposed** (checked 2026-10-09). swift-markdown never sets `CMARK_OPT_FOOTNOTES` and has no footnote node types; `a[^1]` and `[^1]: note` stay literal `Text` in ordinary paragraphs (the definition isn't swallowed as a link reference definition). cmark-gfm itself, which swift-markdown depends on, parses `footnote_reference` and `footnote_definition` nodes with source positions when given `CMARK_OPT_FOOTNOTES`. How to render them is open question 1.
- **F2. Bare-URL autolinks are never parsed** (checked 2026-10-09). swift-markdown attaches only the `table`, `strikethrough` and `tasklist` extensions, not GFM's `autolink`, so `https://…`, `www.…` and emails stay text, and there's nothing to turn off. CommonMark `<https://…>` and `<a@b.c>` are always links. The Autolink setting (FR-8a) needs our own pass over text runs when it's on (or cmark-gfm's `autolink` extension, if cmark-gfm is used directly).
- **F3. Smart punctuation is native and on by default** (checked 2026-10-09). cmark's `CMARK_OPT_SMART` is set unless `ParseOptions.disableSmartOpts` is passed: quotes become curly, `--` an en dash, `---` an em dash and `...` an ellipsis, never inside code. Every parse with Smart punctuation off must pass `.disableSmartOpts` (FR-17); with it on, no pass of our own is needed.
- **F4. Highlight and superscript are not native** (checked 2026-10-09). `==marked==`, `x^2` and `x^(a b)` stay plain `Text`, so FR-19/FR-19a use our own pass over text runs (the plain-text-run limit in docs/MACDOWN-PORT.md).
- **F5. Every block has a source range** (checked 2026-10-09): headings (ATX and setext), paragraphs, block quotes, both list kinds and their items, fenced and indented code, HTML blocks, thematic breaks and tables (with their parts). Columns are 1-based UTF-8 byte offsets, so `LineIndex` converts them to UTF-16.
- **F6. `Markdown.Document` is not `Sendable`** (checked 2026-10-09): returning it from `Task.detached` fails to compile under Swift 6 ("type 'Document' does not conform to the 'Sendable' protocol"); only value types such as `SourceLocation` and `ParseOptions` are `Sendable`. So the Phase 1 model runs all visitors inside the detached task and holds their `Sendable` outputs (body HTML, highlight spans, source-line anchors), not the tree.
- **F7. Math delimiters stay MacDown's** (Phase 1, 2026-10-09). hoedown's bracket math is written `\\(…\\)` and `\\[…\\]` (two backslashes), as help.md documents; a single `\(` is an ordinary Markdown escape, so the protection pass keeps the double form rather than changing what existing documents mean. Inline `$…$` is stricter than hoedown (which took any pair): the opening `$` needs a non-space after it and the closing one a non-space before it and no digit after, so "$5 and $10" isn't math. Math never crosses a blank line or enters code or raw HTML; code is found by a swift-markdown parse, which also covers indented code.
- **F8. NFR-1 can't be met on swift-markdown's tree** (Phase 2 benchmark, 2026-10-09; `HighlightBenchmarkTests`, release build, generated 10k-line document, median ms). PEG highlighting 20.1; the model 73.3 (124.7 with math, highlight and superscript on). Stages: swift-markdown's parse 32.6 on its own (most of it converting cmark's C tree into Swift values), a tree walk 10.7 (the model walks twice: blocks and highlighting), the mapper 22.7, the protection pass with math 47.6 (a second full parse to find code). For comparison, cmark-gfm used directly with every GFM extension, footnotes and source positions, walking every node: 4.5; hoedown's HTML: 2.0. Even with one walk and no second parse, the floor is swift-markdown's parse, which is slower than PEG's whole run. Open question 2.

## Open questions

None open. Resolved: 1. footnote fallback and 2. parser speed, both by Decision 10 (cmark-gfm directly).

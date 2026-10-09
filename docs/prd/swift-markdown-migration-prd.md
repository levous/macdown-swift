# PRD: Migrate Markdown Parsing to swift-markdown

- **Source intent:** [`docs/intents/swift-markdown-migration.md`](../intents/swift-markdown-migration.md) (Accepted, 2026-10-09)
- **Status:** Draft
- **Date:** 2026-10-09
- **Owner:** Rusty Zarse

---

## 1. Problem Statement

### What problem does this solve?

MacDown Swift parses every document twice, with two different C parsers:

- **hoedown** (`Sources/CHoedown`) renders the preview and HTML/PDF export.
- **PEG Markdown Highlight** (`Sources/CPegMarkdown`) colors the editor.

The two grammars disagree at the edges (what counts as emphasis, a list item, a code block), so the editor can color text one way while the preview renders it another. hoedown's last release (3.0.7) is from 2016 and predates CommonMark, so its output no longer matches what users expect from GitHub and other modern Markdown tools.

Scroll sync makes this worse. Neither parser reports source positions to the preview, so `ScrollAnchors` (`Document/ScrollSync.swift`) re-implements hoedown's block rules in Swift to guess where editor lines land in the preview. Every mismatch between that copy and hoedown is a drift bug (for example, the `help.md` code-fence bug).

### Who experiences this problem?

- **Writers** who see editor highlighting that doesn't match the preview, or whose documents render differently in MacDown than on GitHub.
- **Writers of long or image-heavy documents** whose editor and preview drift out of alignment while scrolling.
- **Maintainers** who carry two vendored C parsers, a generated `pmh_parser.c`, MacDown-specific hoedown patches, and a hand-written copy of hoedown's block grammar.

### Current state / workaround

There is none for users. Writers check the preview by eye and live with drift and mismatched highlighting. Maintainers fix scroll-sync bugs one at a time by teaching `ScrollAnchors` another hoedown rule.

---

## 2. Goals

### Primary goal

Parse each document once with swift-markdown (cmark-gfm), and use that single parse for editor highlighting, preview, export and scroll sync.

### Secondary goals

- Follow one principle: **the most expected, standard behavior with the greatest feature support.** Standard Markdown (CommonMark and GFM, plus footnotes and front matter) is always on wherever Markdown is displayed (preview, print, PDF and HTML export, Copy HTML). Extended features are opt-in settings, off by default: highlight, superscript, autolinks, smart punctuation (Settings ▸ Markdown) and math, `[TOC]`, hard wrap, Graphviz (Settings ▸ Rendering).
- Make editing defaults follow Markdown conventions for new installs: list marker `-`, newline at end of file, spaces instead of tabs.
- Align scroll sync by real source positions instead of heuristics.
- Remove both vendored C parser targets and the generated `pmh_parser.c`, adding no new C to the repo.
- Keep all 15 bundled `.style` themes and users' own themes working unchanged.
- Ship with no user-visible regressions in `help.md` and the generated test corpus, apart from documented CommonMark differences and removed syntax.

### Non-goals

- Byte-identical HTML with the original MacDown. This project goal is replaced by "CommonMark/GFM output, with differences listed in the README".
- New Markdown syntax beyond what MacDown supports today.
- Changing existing users' editing settings; new defaults apply to new installs only.
- Keeping `"quote"` → `<q>`: it's dropped in favor of smart punctuation.
- Changing the `.style` theme file format.

---

## 3. Solution / Feature Overview

A new value type, `MarkdownDocumentModel` (`Sendable`), is built once per edit in a background task and consumed by three outputs:

```
MarkdownDocumentModel
  ├─ source + LineIndex          (UTF-8 line/column ↔ UTF-16 offset)
  ├─ protected source            (math and front matter blanked with same-length filler)
  └─ Markdown.Document           (swift-markdown, parsed once per edit)
        ├─ HTMLRenderer      → preview/export body HTML, data-source-line, Prism languages, TOC, math
        ├─ HighlightMapper   → highlight spans keyed by existing theme element names
        └─ SourceAnchors     → scroll-sync anchors from block source positions
```

Main parts:

- **One parse, off the main actor.** It reuses `Renderer.parse`'s detached task and generation counter. The highlighter stops parsing on its own.
- **`LineIndex`** converts swift-markdown's UTF-8 `SourceLocation`s into UTF-16 `NSRange`s for the editor.
- **Protection pass.** Math spans and Jekyll front matter are replaced with same-length filler before parsing, so emphasis rules can't corrupt `$a_1 * b_2$` and every source position stays valid. The renderer emits the original math text by range.
- **`HTMLRenderer`** (a `MarkupVisitor`) produces today's MacDown-specific markup where it matters: Prism-compatible code blocks, task-list classes, `[TOC]`, the front-matter table, footnotes, hard wrap and smart punctuation (if supported). Preview HTML also gets `data-source-line` attributes on blocks.
- **`HighlightMapper`** (a `MarkupWalker`) emits spans named after today's PEG element types (`H1`…`H6`, `EMPH`, `STRONG`, `VERBATIM`, …). Source scans fill the gaps the AST doesn't cover (`REFERENCE`, `HTML_ENTITY`, list markers, comments).
- **`ThemeStyleParser`**, a Swift port of `pmh_styleparser.c`, reads the existing `.style` files.
- **Scroll sync by source line.** The preview reports `[source line, y]` pairs. The editor maps lines to y through `LineIndex` and its layout. `ScrollGeometry` and `ScrollMap` stay, and only the anchor source changes.
- **Staged rollout.** A hidden `markdownEngine` setting (`hoedown` | `swiftMarkdown`) lets both engines run side by side until the switch. After one release with the new default, hoedown and PEG go, and the settings and editing defaults decisions apply (if the early step didn't already apply them).

### Formatting

**Always on (standard):** CommonMark (`_x_`/`*x*` italic, `__x__`/`**x**` bold, intra-word emphasis per CommonMark, `<url>` links, inline and block HTML); GFM tables, fenced code, strikethrough and task lists; footnotes; front matter (a valid leading YAML block renders as a table, as on GitHub). Underline is `<u>…</u>` HTML (toolbar, ⌘U; the setting was already removed). Code syntax highlighting and Mermaid stay on by default.

**Opt-in (extended), off by default;** each keeps its current user defaults key, so existing users keep their choice:

| Feature | Setting | Implementation |
|---|---|---|
| Highlight (`==…==`) | Settings ▸ Markdown | Our own scan (plain text only); not native |
| Superscript (`x^2`, `x^(text)`) | Settings ▸ Markdown | Our own scan (plain text only); not native |
| Autolinks (bare URLs, email addresses) | Settings ▸ Markdown | Our own pass when on; swift-markdown never links them |
| Smart punctuation | Settings ▸ Markdown (today's Smartypants, relabeled) | Native (cmark); parse with `.disableSmartOpts` when off (never in code) |
| Math, inline `$` | Settings ▸ Rendering | Protection pass; MathJax loads from the internet |
| `[TOC]`, hard wrap, Graphviz | Settings ▸ Rendering | Our renderer / page scripts |

**Dropped:** `"quote"` → `<q>` (non-standard; smart punctuation covers typographic quotes).

**Removed settings** (always on now): Table, Fenced code block, Footnote, Strikethrough, Intra-word emphasis, Quote (Settings ▸ Markdown); Task list syntax, Detect Jekyll front-matter (Settings ▸ Rendering).

**Editing defaults (new installs):** list marker `-` (was `*`), ensure newline at end of file on, insert spaces instead of tabs on.

An optional early step can apply the settings and defaults on hoedown before the migration, so the engine switch later is a pure parser change.

---

## 4. User Stories

### Writers

| # | Priority | Story |
|---|---|---|
| US-1 | P0 | As a writer, I want the editor highlighting to match what the preview renders so that I can trust the colors while I type. |
| US-2 | P0 | As a writer, I want my documents to render the way GitHub renders them so that I get the same result in both places. |
| US-3 | P0 | As a writer, I want the preview to stay aligned with the editor while I scroll so that I can see the output for the text I'm editing. |
| US-4 | P0 | As a writer, I want scroll sync to stay aligned in image-heavy documents so that large images don't push the panes apart. |
| US-5 | P0 | As a writer, I want my existing editor theme to keep working so that the editor looks the same after the update. |
| US-6 | P0 | As a writer, I want my custom `.style` theme to keep working so that I don't have to rewrite it. |
| US-7 | P0 | As a writer, I want MathJax formulas with `_` and `*` inside them to render correctly so that equations aren't broken by emphasis. |
| US-8 | P0 | As a writer, I want `[TOC]` to still produce a table of contents so that long documents stay navigable. |
| US-9 | P0 | As a writer, I want fenced code blocks to keep Prism syntax highlighting and line numbers so that code reads the same as before. |
| US-10 | P0 | As a writer, I want task lists to render as checkboxes without turning on a setting so that my to-do documents work like on GitHub. |
| US-11 | P0 | As a writer, I want front matter at the top of a document to render as a table, as GitHub does, without turning on a setting. |
| US-12 | P0 | As a writer, I want HTML and PDF export to use the new renderer so that exports match the preview. |
| US-13 | P1 | As a writer, I want footnotes to render without having to turn anything on so that my references always work. |
| US-14 | P1 | As a writer, I want to turn on smart punctuation (curly quotes, dashes, ellipses) when I want typeset prose, and leave it off by default, so that my straight quotes aren't changed unless I ask. |
| US-15 | P1 | As a writer, I want highlighting to stay smooth in a 10,000-line document so that typing doesn't lag. |
| US-16 | P1 | As a writer, I want the README and help to list the Markdown that's always available, and what was dropped, so that I know why `^text` or `"text"` no longer format. |
| US-17 | P1 | As a writer, I want dropped syntax to show as plain text so that none of my content disappears. |
| US-17a | P0 | As a writer, I want standard Markdown to work in the preview, print and export without hunting for settings, with only extended features (highlight, superscript, autolinks, smart punctuation, math, `[TOC]`, hard wrap, Graphviz) as opt-in choices, so that my documents look the way Markdown is expected to look. |
| US-17b | P1 | As a new user, I want the editor to insert conventional Markdown (`-` list items, spaces, a trailing newline) so that my files match common style guides and linters. |
| US-18 | P2 | As a writer, I want math spans colored in the editor so that I can see where formulas start and end. |
| US-19 | P2 | As a writer, I want to switch back to the old engine for one release so that I can keep working if the new one breaks a document. |

### Maintainers

| # | Priority | Story |
|---|---|---|
| US-20 | P0 | As a maintainer, I want one parser behind one model type so that the editor and preview can't disagree. |
| US-21 | P0 | As a maintainer, I want an HTML diff between the two engines over a corpus so that I can review every rendering change. |
| US-22 | P0 | As a maintainer, I want a highlight-span diff per element type so that I can find highlighting regressions. |
| US-23 | P1 | As a maintainer, I want the two C parser targets removed so that there's less vendored and generated code to maintain. |
| US-24 | P1 | As a maintainer, I want swift-markdown's API used in only one file so that a pre-1.0 API change is cheap to absorb. |

---

## 5. Requirements

### Functional Requirements

**Parsing and model**

1. FR-1: The app parses a document once per edit, in a background task, into a `MarkdownDocumentModel`. The highlighter, preview, export and scroll sync all read from that model.
2. FR-2: A parse result whose generation is older than the latest edit is discarded, as `Renderer.parse` does today.
3. FR-3: `LineIndex` converts any swift-markdown `SourceLocation` (UTF-8 column) into the correct UTF-16 offset, including for emoji, surrogate pairs and CRLF line endings.
4. FR-4: The protection pass finds `$$…$$`, `\\[…\\]`, `\\(…\\)` (MacDown's double-backslash syntax, finding F7), and (only when inline dollars are on) `$…$`, and skips code spans, code blocks and raw HTML.
5. FR-5: The protection pass replaces each protected span with filler of the same UTF-8 length that has no Markdown meaning, so every source position after it is unchanged.
6. FR-6: A valid YAML front matter block at the very top is blanked with same-length filler rather than cut, so line numbers in the parse match the editor.

**Preview and export rendering**

7. FR-7: Core blocks and inlines render as CommonMark HTML.
8. FR-8: Tables, fenced code, strikethrough and task lists always render as GFM; there is no setting to turn them off.
8a. FR-8a: With the Autolink setting on (off by default), bare URLs and email addresses render as links through cmark-gfm's `autolink` extension, attached only then; off, they render as plain text. `<url>` autolinks (CommonMark) always render as links.
9. FR-9: Fenced code blocks render as `<div><pre class="line-numbers" data-information><code class="language-…">`, the same markup as today, with the line-numbers class only when that setting is on.
10. FR-10: Each code-block language is added to the parse result's Prism language list, with today's alias mapping from `languageAddition`.
11. FR-11: Task list items always render with MacDown's current task-list markup and classes; there is no setting.
12. FR-12: When `[TOC]` rendering is on, a paragraph whose only content is `[TOC]` is replaced with a table of contents built from the document's headings, using today's TOC classes and anchor links.
13. FR-13: When hard wrap is on, soft line breaks render as `<br>`.
14. FR-14: When MathJax is on, protected math spans are emitted as the original source text, unescaped, so MathJax can typeset them.
15. FR-15: A valid YAML front matter block at the very top always renders as today's HTML table (Yams) before the body; there is no setting. A leading `---` that isn't valid YAML renders as ordinary Markdown.
16. FR-16: Footnote references and definitions always render as footnotes.
17. FR-17: With the Smart punctuation setting on (off by default; today's Smartypants key), prose renders curly quotes, en/em dashes and ellipses, never inside code; natively if swift-markdown supports it, otherwise by our own pass over text nodes. Off, punctuation is left as typed.
18. FR-18: Preview HTML includes a `data-source-line` attribute on every block element. Exported HTML and PDF don't.
19. FR-19: With the Superscript setting on (off by default), `x^2` and `x^(text)` render as `<sup>`, natively if swift-markdown supports it, otherwise by splitting plain-text runs; the editor colors it with a new highlight type. Off, `^` is plain text. `"text"` always renders as typed (Quote is dropped). `_text_` is emphasis and `__text__` strong; underline is `<u>…</u>` HTML.
19a. FR-19a: With the Highlight setting on (off by default), `==text==` renders as `<mark>text</mark>`, natively if swift-markdown supports it, otherwise by splitting plain-text runs (markers around other formatting don't highlight), and the editor colors it with a new highlight type. Off, `==text==` is plain text.
20. FR-20: `PageBuilder` builds the preview and export pages unchanged apart from where the `ParseResult` comes from. Mermaid, Graphviz, MathJax and Prism keep working.

**Editor highlighting**

21. FR-21: `HighlightMapper` produces spans named after today's theme element types (`H1`…`H6`, `EMPH`, `STRONG`, `HRULE`, `LIST_BULLET`, `LIST_ENUMERATOR`, `LINK`, `AUTO_LINK_URL`, `AUTO_LINK_EMAIL`, `REFERENCE`, `IMAGE`, `CODE`, `VERBATIM`, `HTML_ENTITY`, `COMMENT`, `BLOCKQUOTE`, and the rest of the set the themes use).
22. FR-22: Source scans produce `REFERENCE` definitions, `HTML_ENTITY`, list markers and `<!-- -->` comment spans where the AST has no matching node.
23. FR-23: Math spans get a new highlight type. Themes that don't define a style for it leave math uncolored.
24. FR-24: `ThemeStyleParser` reads all 15 bundled themes and produces the same styles as `pmh_styleparser.c` for each.
25. FR-25: User-installed `.style` themes load and apply with no edits.
26. FR-26: `MarkdownHighlighter` keeps debouncing and styling only the visible range, and takes its spans from the model.
27. FR-27: The editor highlights footnote references and definitions with a `NOTE` span type. (Today's PEG highlighter defines `NOTE` but never emits it, so footnotes aren't colored with either value of its footnote flag.)

**Scroll sync**

28. FR-28: The preview reports block positions as `[source line, y]` pairs read from `data-source-line`.
29. FR-29: The editor maps a source line to a y position through `LineIndex` and its text layout.
30. FR-30: `ScrollAnchors.scan` and its kind-matching logic are replaced by a source-line map. `ScrollGeometry` and `ScrollMap` stay.
31. FR-31: Scroll sync stays aligned in both directions (editor → preview, preview → editor) with unequal pane widths.

**Rollout and cleanup**

32. FR-32: A hidden `markdownEngine` setting (`hoedown` | `swiftMarkdown`) selects the engine for all four outputs. Default is `hoedown` until Phase 5.
33. FR-33: In Phase 5 the default becomes `swiftMarkdown` for one release, with `hoedown` still selectable.
34. FR-34: After that release, `Sources/CHoedown`, `Sources/CPegMarkdown`, the hidden setting and `ScrollAnchors`' scanner are removed.
35. FR-35: Settings ▸ Markdown keeps only Highlight, Superscript, Autolink and Smart punctuation (relabeled from Smartypants), off by default, with their existing user defaults keys. Table, Fenced code block, Footnote, Intra-word emphasis, Strikethrough and Quote are removed. Settings ▸ Rendering loses Task list syntax and Detect Jekyll front-matter. Removed settings lose their `Preferences` properties and hoedown flag mapping (always on, except Quote, which is off). (Underline was removed on 2026-10-09.) This may ship early on hoedown.
35a. FR-35a: On a new install, the editor defaults are: unordered list marker `-`, ensure newline at end of file on, insert spaces instead of tabs on. Existing users' values are unchanged.
36. FR-36: The user defaults keys of dropped settings stay untouched in the user's defaults, so a downgrade still finds them.
37. FR-37: `Licenses/` drops hoedown and PEG Markdown Highlight and adds swift-markdown and swift-cmark.
38. FR-38: README ("Differences from the original", layout table; "Regenerating the highlighter parser" removed), CLAUDE.md (render pipeline, Editor, Tests, output goal) and `help.md` (Inline Formatting table and footnotes, Smartypants paragraph) describe the new behavior.

### Non-Functional Requirements

**Performance**

- NFR-1: On a 10,000-line document, the time from an edit to updated highlighting is no worse than PEG's today (measured in Phase 2 on the same machine and document).
- NFR-2: The main actor never runs a parse. Typing doesn't stall while a parse runs.
- NFR-3: Total parse work per edit drops compared with today, because one parse replaces two.

**Accessibility**

- NFR-4: Rendered HTML keeps the semantic elements it has today (headings, lists, tables, `<input type="checkbox">` for tasks), so VoiceOver reads the preview at least as well as before.
- NFR-5: Editor highlight colors and fonts come from the same theme values as today, so contrast doesn't change for existing themes.
- NFR-6: Any new or changed Settings UI strings use `String(localized:)`, go into `App/Localizable.xcstrings`, and fall back to English.

**Platform**

- NFR-7: macOS 15+, Swift 6.4 toolchain, Xcode 27, unchanged from today.
- NFR-8: Builds cleanly with strict concurrency (`swiftLanguageModes: [.v6]`, `SWIFT_STRICT_CONCURRENCY: complete`).
- NFR-9: The `macdown` shell utility and its shared defaults keys are unaffected.

### Technical Requirements

- TR-1: swift-cmark (`cmark-gfm`, `cmark-gfm-extensions`) is a SwiftPM dependency pinned to an **exact** version; no new C goes into the repo. (swift-markdown was used for the Phase 0 spikes and is dropped: intent Decision 10.)
- TR-2: Only the model folder (`Document/Model`) calls the cmark-gfm C API, so the parser is contained in one place.
- TR-3: `MarkdownDocumentModel` and everything it contains are value types that conform to `Sendable`.
- TR-4: `HTMLRenderer` and `HighlightMapper` walk cmark-gfm's node tree inside the parse task; both are pure (no app state, no main-actor isolation), and only their `Sendable` results leave it.
- TR-5: Renderer-specific markup that used to live in `hoedown_html_patch.c` (task lists, code-block info, Prism code blocks, TOC classes) moves into `HTMLRenderer`.
- TR-6: Resource directories added for the corpus or new themes are listed in `Package.swift`'s `resources:`.
- TR-7: Tests use Swift Testing (`@Suite`/`@Test`). Live-preview tests run in the serialized `LiveDocumentTests` group.
- TR-8: Phase 0 builds two diff tools (tests or `Tools/` scripts), both runnable in CI on both engines until Phase 5:
  - an HTML diff, hoedown vs swift-markdown, normalized for whitespace and attribute order;
  - a highlight-span diff, PEG vs swift-markdown, per element type.
- TR-9: The corpus is generated test fixtures in `Tests/MacDownKitTests/Resources/Corpus/` (purpose-written Markdown, one file per feature area plus edge cases and a programmatically generated 10k-line document), plus the bundled `help.md`. Real user documents and other docs are never used as fixtures.

---

## 6. Success Metrics

| Metric | Target | How measured |
|---|---|---|
| Parses per edit | 1 (down from 2) | Instrumentation or code review of the pipeline |
| Vendored C parser targets | 0 (down from 2), no generated parser source | Package.swift and repo tree after Phase 5 |
| Unreviewed HTML diffs on the corpus | 0 | HTML diff tool; every remaining diff is an intended CommonMark difference listed in the README |
| Unreviewed highlight-span diffs on the corpus | 0 per element type | Span diff tool |
| Themes loading with identical styles | 15 / 15 bundled | `ThemeStyleParser` vs `pmh_styleparser.c` comparison test |
| Highlight latency, 10k-line file | ≤ PEG baseline | Phase 2 benchmark |
| Scroll-sync drift on `help.md` and image-heavy docs | No visible drift at any scroll position, both directions | `ScrollSyncTests` plus manual pass |
| Scroll-sync bug reports after release | Fewer than the previous two releases | Issue tracker |
| Rollback use | No document needs the `hoedown` fallback by the end of the fallback release | Issue tracker and maintainer testing |

### Acceptance Criteria

**All phases**
- [ ] `HelpDocumentTests` passes (rendering, editor highlighting, and the real preview of `Resources/help.md`), and `help.md` is updated in the same change as any feature it documents.

**Phase 0: Spike and parity harness**
- [ ] swift-markdown is pinned to an exact version in `Package.swift` and builds under Swift 6 strict concurrency.
- [x] "Decisions" in the intent doc records answers on footnotes, smart punctuation, native support for highlight and superscript, source positions on every block node, and concurrency compatibility.
- [ ] The HTML diff compares swift-markdown against hoedown with the same formatting: the always-on set, plus each opt-in feature off and on.
- [x] Phase 0 records whether GFM autolinks can be turned off at parse time, and whether smart punctuation, highlight and superscript are native.
- [x] Today's behavior of the inline formatters (hoedown, each toggle on) is checked and recorded: they work (see "Dropped features" in the intent doc), so dropping any of them is a user-visible removal for the release notes.
- [ ] The corpus is checked in.
- [ ] Both diff tools run in CI. Diffs caused by dropped features are listed once.

**Phase 1: Shared model**
- [ ] `LineIndex` tests pass for ASCII, emoji, surrogate pairs and CRLF.
- [ ] Protection-pass tests show byte offsets are unchanged after protection.
- [ ] Math spans with `_`, `*` and `\` survive emphasis-heavy content unchanged.
- [ ] Escaped `\$`, `$` inside code, and currency amounts aren't treated as math.

**Phase 2: Highlighter**
- [ ] The highlight-span diff on the corpus shows only intended differences.
- [ ] `ThemeStyleParser` output matches `pmh_styleparser.c` for all 15 bundled themes.
- [ ] `HighlighterTests` are ported and pass on the new engine.
- [ ] Re-highlight time on a 10k-line file is ≤ the PEG baseline.

**Phase 3: Renderer**
- [ ] `RendererTests` pass on both engines. Every expectation changed for CommonMark is noted in the test or README.
- [ ] The HTML diff on the corpus has been reviewed, and remaining differences are listed in the README.
- [ ] Mermaid, Graphviz, MathJax and Prism render in the running app.
- [ ] HTML and PDF export contain no `data-source-line` attributes.
- [ ] Tests confirm `==x==`, `^x` and `"x"` render as plain text and `_x_` as `<em>`.
- [ ] TOC, task lists, front matter (valid and invalid YAML), footnotes and code-block markup have unit tests; a test shows standard formatting renders with default (empty) user defaults; each opt-in feature has off (plain text) and on tests; `"text"` renders as typed.

**Phase 4: Scroll sync**
- [ ] `ScrollSyncTests` pass with source-line anchors.
- [ ] `help.md` (including the code-fence case) and an image-heavy document stay aligned with unequal pane widths, scrolling either pane.

**Phase 5: Switch and remove**
- [ ] One release ships with `swiftMarkdown` as the default and `hoedown` reachable.
- [ ] The following release removes `CHoedown`, `CPegMarkdown`, the hidden setting and the old scanner. `swift build`, `swift test` and the Xcode build pass.
- [ ] Settings ▸ Markdown shows only Highlight, Superscript, Autolink and Smart punctuation, and Settings ▸ Rendering no longer shows Task list syntax or Detect Jekyll front-matter; opt-in features are off for new users and unchanged for existing users; removed settings' defaults keys are still present.
- [ ] A fresh install has list marker `-`, newline at end of file and spaces for tabs; an existing install keeps its values.
- [ ] `Licenses/`, README, CLAUDE.md and `help.md` are updated as listed in FR-37 and FR-38.

---

## 7. Scope

### In Scope

- Replacing hoedown and PEG Markdown Highlight with swift-markdown for preview, export, editor highlighting and scroll sync.
- `MarkdownDocumentModel`, `LineIndex`, the math/front-matter protection pass, `HTMLRenderer`, `HighlightMapper`, `ThemeStyleParser` and source-position scroll sync.
- The parity corpus and the HTML and highlight-span diff tools.
- The hidden engine setting and the staged rollout.
- Applying the settings decisions (FR-35) and editing defaults (FR-35a), and updating README, CLAUDE.md, `help.md` and licenses.
- Footnotes always highlighted in the editor (replaces the inverted footnote flag).

### Out of Scope

- Byte-identical output with the original MacDown.
- New Markdown syntax; keeping `"quote"` → `<q>`; settings to turn standard Markdown off; changing existing users' editing settings.
- Changes to the `.style` format, or new bundled themes.
- Changes to `PageBuilder`, `HTMLTemplate`, assets or preview styles beyond the new `ParseResult` source.
- Changes to `macdown-cmd` or the app ↔ shell-utility defaults keys.

### Future Considerations

- Building editor features on the shared AST: outline/sidebar navigation, heading folding, smarter list continuation in `NSTextView+Autocomplete.swift`.
- Using source positions for click-to-locate between preview and editor.
- Incremental re-parsing of only the edited blocks, if large-file performance needs it.
- An optional plugin for math or other syntax if swift-markdown gains extension points.
- Exporting the AST (for example to JSON) for the `macdown` CLI.

### Resolved

- **Principle:** the most expected, standard behavior with the greatest feature support. Standard Markdown is always on (FR-8, FR-11, FR-15, FR-16); extended features are opt-in, off by default (FR-8a, FR-17, FR-19, FR-19a, FR-35).
- **Underline:** `<u>…</u>` HTML; the setting is removed (already done). Underscores follow standard Markdown.
- **Highlight:** kept as a setting, natively or with our own scan (FR-19a).
- **Superscript:** kept as a setting, natively or with our own scan (FR-19).
- **Quote:** dropped; smart punctuation covers typographic quotes (FR-19).
- **Settings ▸ Rendering:** task lists and front matter always on; math stays opt-in (MathJax needs a network connection); `[TOC]`, hard wrap and Graphviz opt-in; code highlighting and Mermaid on by default (FR-35).
- **Editing defaults:** conventions for new installs (FR-35a).
- **Smart punctuation:** kept as a setting, natively or with our own pass (FR-17).
- **Corpus:** generated fixtures plus `help.md`; never real user documents or other docs (TR-9).
- **Verification:** every phase is verified in the running app as well as by tests (launch a throwaway build, capture its window, check exports).
- **Inverted footnote highlighting:** harmless; PEG never emits `NOTE`, so footnotes aren't colored today either way. The new highlighter colors them (FR-27).

### Open Questions

None open. Footnote fallback (1) and parser speed (2) were resolved on 2026-10-09 by building on cmark-gfm directly (intent Decision 10).

# Ralph Fix Plan: Migrate Markdown Parsing to swift-markdown

Source: `docs/prd/swift-markdown-migration-prd.md` (PRD, Draft 2026-10-09) and
`docs/intents/swift-markdown-migration.md` (intent, Accepted).
Detailed spec: `.ralph/specs/swift-markdown-migration-requirements.md`.

Work top to bottom. Each phase lands behind the hidden `markdownEngine` setting
(default `hoedown`) until Phase 5. Every change that touches a documented feature
updates `Sources/MacDownKit/Resources/help.md` in the same commit, and
`HelpDocumentTests` must pass after every task (`swift test`).

**Verify everything yourself.** Every task is verified with tests and, when it
changes anything visible, in the running app: build a throwaway copy, launch it
with fixture documents, capture its window with
`swift Tools/capture-window.swift MacDown <out.png> [title]`, and look at the
screenshot (and exported HTML/PDF where relevant). Stop only when something
can't be verified with the available capabilities; then ask the user to enable
what's missing (see the first task).

## High Priority

### Prerequisite: verification capabilities
- [x] Screen capture of app windows works (checked 2026-10-09: `Tools/capture-window.swift` captured a throwaway MacDown build's window showing a fixture document)
- [ ] UI control (clicks, keystrokes, menus in MacDown through System Events) is **not authorized** (2026-10-09: "Not authorized to send Apple events to System Events"). Until enabled, drive the app with temporary environment-gated probes (see `.claude/commands/goal.md`). If a task can only be verified by UI control, stop and ask the user to allow the host app under System Settings ▸ Privacy & Security ▸ Automation (System Events) and ▸ Accessibility

### Early step: settings and defaults on hoedown (FR-35, FR-35a, FR-36; optional but recommended first)
- [x] `Renderer.swift` (`Preferences.renderSettings` / hoedown flag mapping): always set tables, fenced code, footnotes, strikethrough, intra-word emphasis; never set quote
- [x] `Renderer.swift` / `MarkdownParser.swift`: always render task lists and always detect Jekyll front matter (no longer read `htmlTaskList`, `htmlDetectFrontMatter`)
- [x] `Preferences.swift`: remove properties `extensionTables`, `extensionFencedCode`, `extensionFootnotes`, `extensionStrikethough`, `extensionIntraEmphasis`, `extensionQuote`, `htmlTaskList`, `htmlDetectFrontMatter`; do NOT delete their keys from user defaults (FR-36), and drop them from any `keysToRemove`-style cleanup if listed there
- [x] `DocumentController.swift` (~line 764): highlighter footnote extension always on; drop the `extensionFootnotes` observation and its entry in the observed-keys list (~line 107)
- [x] `SettingsView.swift`: `MarkdownSettingsView` shows only Highlight, Superscript, Autolink, and "Smart punctuation" (relabeled Smartypants, key `extensionSmartyPants`); Rendering pane drops Task list syntax and Detect Jekyll front-matter
- [x] Add new/changed UI strings via `String(localized:)` to `App/Localizable.xcstrings`; run `python3 Tools/import_localizations.py <original macdown>` if available (NFR-6)
- [x] `Preferences.loadDefaultPreferences` (fresh install only): `editorUnorderedListMarkerType = .minusSign`, `editorEnsuresNewlineAtEndOfFile = true`, `editorConvertTabs = true`; remove now-dead `extensionFootnotes = true` default
- [x] Tests (`PreferencesTests` in `CoreTests.swift`): fresh install gets new editing defaults; existing install keeps values; removed keys remain in defaults
- [x] Tests (`RendererTests`): standard formatting (table, fence, strikethrough, footnote, task list, front matter) renders with empty user defaults; `"text"` renders as typed (no `<q>`)
- [x] `help.md`: rewrite "The Markdown Preference Pane", Inline Formatting table and Quote footnote, Smartypants paragraph, Rendering pane section (task lists, front matter); update `HelpDocumentTests` expectations
- [x] docs/MACDOWN-PORT.md "Differences from the original": note always-on standard features, dropped Quote, new editing defaults (removing "Regenerating the highlighter parser" waits for the hoedown/PEG removal)
- [x] Front matter detection: require the closing `---`/`...` on its own line and a YAML mapping, so a document that opens with a thematic break isn't swallowed now that detection is always on (found by the corpus, 2026-10-09)

### Phase 0: Spike and parity harness (TR-1, TR-8, TR-9)
- [x] Add `swift-markdown` to `Package.swift` pinned with `.exact(...)` (0.9.0; swift-cmark resolves to 0.9.0); add `.product(name: "Markdown", package: "swift-markdown")` to `MacDownKit`; confirm `swift build` and the Xcode build under strict concurrency (NFR-8)
- [x] Spike: confirm swift-markdown exposes cmark-gfm footnotes. **Answer (F1): not exposed**; the syntax stays literal text, and cmark-gfm parses footnotes directly with `CMARK_OPT_FOOTNOTES`. The fallback choice is PRD Open Question 1, still open (now three options, including cmark-gfm directly)
- [x] Spike: can GFM autolinks (bare URLs/emails) be disabled at parse time? **Answer (F2): they are never parsed**, so nothing to disable; the Autolink setting needs our own text-run pass (or cmark-gfm's `autolink` extension)
- [x] Spike: native support for smart punctuation, `==highlight==`, `^superscript`? **Answer (F3, F4): smart punctuation native; highlight and superscript need our own pass**
- [x] Spike: does swift-markdown/cmark apply smart punctuation BY DEFAULT (look for a `disableSmartOpts`-style `ParseOptions` flag)? If so, FR-17 requires passing the disable option whenever the setting is off **Answer (F3): yes**; pass `.disableSmartOpts` whenever the setting is off
- [x] Spike: does every block node carry a `SourceRange`? Is `Markdown.Document` `Sendable` / usable from a detached task under Swift 6? (`Markup` is a struct over a class-backed tree; verify specifically, it decides the Phase 1 model shape) **Answer (F5, F6): yes, every block has a range (UTF-8 columns); `Document` is NOT `Sendable`**, so the model holds visitor outputs
- [x] Record all spike answers in "Decisions" of `docs/intents/swift-markdown-migration.md` (findings F1–F6 under "Phase 0 findings")
- [x] Add hidden `markdownEngine` user default (`hoedown` | `swiftMarkdown`, default `hoedown`) in `Preferences.swift`, not shown in Settings (FR-32)
- [x] Generate the corpus in `Tests/MacDownKitTests/Resources/Corpus/` (TR-9): purpose-written Markdown, one file per area, each with edge cases — inline (emphasis/strong nesting, intra-word `*` and `_`, escapes, code spans with backticks), blocks (setext/ATX headers, lists: nested, mixed markers, ordered start numbers, loose/tight, list items with code), block quotes (nested, lazy), code (indented, fenced with ``` and ~~~, longer/shorter closing fences, fences inside code spans as in help.md, info strings `lang:label`), links and images (inline, reference, titles, `<url>`, emails, relative paths, image-only paragraphs, images in links), tables (alignment, escaped pipes, inline formatting), HTML (inline, blocks, comments, entities), footnotes, front matter (valid, invalid YAML, leading `---` rule), task lists, `[TOC]`, math (`$`, `$$`, `\(`, currency `$`, escaped `\$`, math in code), the opt-in syntax (`==`, `^`, bare URLs, smart quotes/dashes), Mermaid/Graphviz blocks, Unicode/emoji/CRLF, an image-heavy document for scroll sync; plus a 10k-line document generated in the test. Keep `help.md` as a corpus document. No real user documents or other docs
- [x] HTML diff harness (Swift Testing suite or `Tools/` script): corpus loader, whitespace/attribute-order normalizer, report format, settings matrix (always-on set plus each opt-in off and on); prove it on hoedown vs hoedown (or vs swift-markdown's built-in HTML formatter if the spike finds one). The real hoedown-vs-`HTMLRenderer` run happens at the end of Phase 3
- [x] Highlight-span diff harness: per-element-type span comparison and report, proven on PEG vs PEG. The real PEG-vs-`HighlightMapper` run happens at the end of Phase 2
- [x] Expected-diff list file: diffs caused by dropped features (Quote) listed once, not per document (`Tests/MacDownKitTests/Resources/expected-html-diffs.json`; Quote no longer differs since the early step removed it from hoedown, so it starts with the CommonMark intra-word underscore rules)
- [x] Wire both harnesses into CI (or document the `swift test --filter` invocation if no CI exists) (no CI; documented in README "Migration diff harnesses" and CLAUDE.md); they gain the swift-markdown side as Phases 2 and 3 land

### Phase 1: Shared model (FR-1 to FR-6, TR-2, TR-3)
- [x] `LineIndex` (value type, `Sendable`): UTF-8 line/column (swift-markdown `SourceLocation`) to UTF-16 offset and `NSRange`; handles emoji, surrogate pairs, CRLF
- [x] Tests: `LineIndex` for ASCII, emoji, surrogate pairs, CRLF
- [x] Protection pass: find `$$…$$`, `\[…\]`, `\(…\)`, and `$…$` only when inline dollars are on; skip code spans and fenced code blocks; replace with same-UTF-8-length filler with no Markdown meaning
- [x] Front matter: valid leading YAML block blanked with same-length filler (not cut); invalid YAML left untouched
- [x] Tests: byte offsets unchanged after protection; math with `_`, `*`, `\` survives emphasis-heavy content; escaped `\$`, `$` in code and currency amounts are not math
- [x] `MarkdownDocumentModel` (`Sendable`): source, `LineIndex`, protected source, protected math/front-matter ranges, `Markdown.Document`; only this file area imports `Markdown` (TR-2)
  - Shape depends on the Phase 0 Sendable spike: if `Markdown.Document` is not `Sendable`, run all three visitors inside the detached task and have the model hold their `Sendable` outputs (body HTML, `[HighlightSpan]`, source-line anchors), not the tree
- [x] `Renderer.parse`: when `markdownEngine == swiftMarkdown`, build the model in the existing detached task and keep the generation counter that discards stale results (FR-2, NFR-2)

## Medium Priority

### Phase 2: Highlighter (FR-21 to FR-27, NFR-1)
- [x] `ThemeStyleParser`: Swift port of `Sources/CPegMarkdown/pmh_styleparser.c` (same element names, attributes, colors, font traits, error messages)
- [x] Test: `ThemeStyleParser` output equals `pmh_styleparser.c` output for all 15 themes in `Resources/Themes`
- [x] `MarkdownHighlighter.applyStyles(fromStylesheet:)` uses `ThemeStyleParser` instead of `pmh_parse_styles` (needed before Phase 5 removes CPegMarkdown; same error strings)
- [x] `HighlightMapper` (`MarkupWalker`, pure): spans for `H1`…`H6`, `EMPH`, `STRONG`, `HRULE`, `LINK`, `AUTO_LINK_URL`, `AUTO_LINK_EMAIL`, `IMAGE`, `CODE`, `VERBATIM`, `BLOCKQUOTE`, `HTMLBLOCK`, and the rest of the PEG set used by themes
- [x] Source scans for gaps: `REFERENCE` definitions, `HTML_ENTITY`, `LIST_BULLET`/`LIST_ENUMERATOR` markers, `<!-- -->` `COMMENT`
- [x] `NOTE` spans for footnote references and definitions (FR-27)
- [x] New highlight types: math (FR-23), highlight `==…==` and superscript `^` (only with their settings on); themes without a style leave them uncolored
- [x] `DocumentController`: hand the latest model (or its spans) from `Renderer.parse` to `MarkdownHighlighter` when engine is `swiftMarkdown`; Phase 4 reuses this path for scroll sync (FR-1)
- [x] `MarkdownHighlighter`: take spans from the model when engine is `swiftMarkdown`; keep debounce and visible-range styling (FR-26); stop its own parse
- [x] Port `HighlighterTests` (`EditorTests.swift`) and `HelpDocumentHighlightingTests` to run on the new engine
- [x] Benchmark: re-highlight time on a 10k-line document vs PEG baseline on the same machine; record numbers (NFR-1). **Recorded (F8): PEG 20.1 ms, model 73.3 ms (124.7 with math and opt-ins), cmark-gfm direct 4.5 ms. NFR-1 not met; PRD Open Question 2 (relax NFR-1, or cmark-gfm directly) must be decided before Phase 3**
- [x] Run the span-diff harness PEG vs `HighlightMapper` on the corpus and review; only intended differences remain (reviewed list in `HighlightDiffHarnessTests.reviewed`; a new difference fails the test)
  - Done: a header inside a block quote is colored (`HighlightMapperTests.headerInBlockQuote`)

### Phase 2b: Move onto cmark-gfm (Decision 10)
- [x] `Package.swift`: MacDownKit depends on swift-cmark's `cmark-gfm` and `cmark-gfm-extensions` (exact 0.9.0)
- [x] `CMarkTree` (in `Document/Model`): parse with `CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES` (+ `CMARK_OPT_SMART` when on), extensions `table`, `strikethrough`, `tasklist` (+ `autolink` when on); node type, children, literal, positions (cmark end columns are inclusive); frees the tree; never leaves the parse task
- [x] `ProtectedSource`: code and raw HTML ranges from one cmark parse instead of swift-markdown
- [x] `MarkdownDocumentModel`: blocks from cmark nodes, in the same walk as highlighting (one walk)
- [x] `HighlightMapper` on cmark nodes: same spans and extents (all existing tests pass); NOTE from footnote nodes; AUTO_LINK_URL/EMAIL also for extension autolinks when Autolink is on; update the reviewed PEG diff list
- [x] Remove swift-markdown: dependency, imports, swift-markdown spike tests (findings stay recorded in the intent); `LineIndexTests` corpus check uses cmark positions
- [x] Benchmark: NFR-1 met on 10k lines (remove the known issue); record numbers in F8. **Recorded: 14.6 ms vs PEG 19.7 at defaults; 20.5 ms with math and opt-ins (4% over PEG, within the test's 10% allowance)**

### Phase 3: Renderer (FR-7 to FR-20, TR-4, TR-5)

Built on cmark-gfm's node tree (Decision 10), after Phase 2b.
- [x] `HTMLRenderer` (pure, walks cmark-gfm nodes inside the parse task): CommonMark core blocks and inlines
- [x] GFM tables, strikethrough, fenced code always on
- [x] Code blocks: `<div><pre class="line-numbers" data-information><code class="language-…">`, line-numbers class only when setting on; port `hoedown_html_patch.c` code-block info (FR-9)
- [x] Prism language list with `languageAddition` alias mapping moved out of `MarkdownParser.swift` (FR-10)
- [x] Task lists with MacDown's current markup/classes, always on (FR-11)
- [x] Footnotes always on (FR-16), from cmark-gfm footnote nodes (`CMARK_OPT_FOOTNOTES`), with today's footnote markup
- [x] Front matter table via Yams before body, always on; invalid YAML renders as Markdown (FR-15)
- [x] `[TOC]` paragraph replaced by TOC from `Heading` nodes, today's classes and anchors, when setting on (FR-12)
- [x] Hard wrap: soft breaks as `<br>` when on (FR-13)
- [x] Math pass-through when MathJax on (FR-14): hoedown's MathJax delimiters, content escaped (the page's MathJax 2 needs `\(` and `\[`; FR-14 updated)
- [x] Autolink: bare URLs/emails linked only when setting on, by attaching cmark-gfm's `autolink` extension; `<url>` always linked (FR-8a)
- [x] Smart punctuation when on, never inside code (FR-17), via `CMARK_OPT_SMART`
- [x] Highlight `<mark>` and superscript `<sup>` (`x^2`, `x^(text)`) when on; plain-text-run scan if not native (FR-19, FR-19a)
- [x] `data-source-line` on every block element in preview HTML only; export/PDF/Copy HTML clean (FR-18)
- [x] Route `ParseResult` from the new engine into `PageBuilder` unchanged (FR-20)
- [x] Tests: `RendererTests` pass on both engines (no expectation needed changing); each CommonMark-changed expectation commented in the test or docs/MACDOWN-PORT.md
- [x] Tests: `==x==`, `^x`, `"x"` plain text by default; `_x_` is `<em>`; each opt-in off and on; TOC, task list, front matter (valid/invalid), footnotes, code-block markup; standard formatting with empty defaults
- [x] Test: HTML/PDF export contains no `data-source-line`
- [x] Live test: Mermaid, Graphviz, MathJax, Prism render in the running app (`LiveDocumentTests`), and a screenshot of the corpus documents in a throwaway build looks right
- [x] Run the HTML-diff harness hoedown vs `HTMLRenderer` on the corpus (full settings matrix) and review; remaining differences listed in docs/MACDOWN-PORT.md

### Phase 4: Scroll sync by source line (FR-28 to FR-31)
- [x] `PreviewController.fetchMetrics` JS: report `[sourceLine, y]` pairs from `[data-source-line]` elements instead of `h`/`i` kinds
- [x] `DocumentController`: pass the model's source-line data to scroll sync via the Phase 2 model hand-off (not needed: the editor computes the preview's lines from its own text)
- [x] `SourceAnchors`: editor maps source line to y via `LineIndex` and the text layout
- [x] Replace `ScrollAnchors.scan` and kind matching with a source-line map feeding the existing `ScrollMap`; keep `ScrollGeometry` and `ScrollMap` (with the new engine; `scan` stays for hoedown until Phase 5 removes it)
- [x] Update `ScrollAnchorsTests` / `ScrollSyncIntegrationTests` for source-line anchors
- [x] Verify `help.md` (code-fence case) and an image-heavy document stay aligned with unequal pane widths, both scroll directions

## Low Priority

### Phase 5: Switch and remove (FR-33, FR-34, FR-37, FR-38)
- [x] Default `markdownEngine` to `swiftMarkdown`, `hoedown` still selectable (ship one release; human release gate). **Default switched 2026-10-09; shipping the release is the user's step**
- [ ] After that release: remove `Sources/CHoedown`, `Sources/CPegMarkdown`, their `Package.swift` targets/dependencies, the hidden setting, and `ScrollAnchors.scan` (BLOCKED: awaiting the release with cmark-gfm as default)
- [x] Apply early-step settings/defaults here if the early step didn't ship (not needed: the early step is done)
- [ ] `Licenses/`: remove `hoedown.txt`, `peg-markdown-highlight.txt` (check whether `hoextdown.txt` is only needed for hoedown patches; remove if so); add swift-markdown and swift-cmark licenses (cmark-gfm.txt added 2026-10-09; the removals are BLOCKED: awaiting the hoedown removal)
- [x] docs/MACDOWN-PORT.md "Differences from the original" (CommonMark output, always-on, opt-in, dropped syntax, plain-text-run limit for highlight/superscript); docs/ARCHITECTURE.md: layout/class table, Markdown engine section, remove "Regenerating the highlighter parser"
- [x] CLAUDE.md and docs/ARCHITECTURE.md: render pipeline, Editor, Tests, and drop the byte-identical HTML output goal
- [ ] `help.md`: final pass for footnotes, Inline Formatting, Smart punctuation
- [ ] `swift build`, `swift test`, `xcodegen generate` + `xcodebuild` all pass

### Future (out of scope; do not implement)
- Outline/heading folding, click-to-locate, incremental re-parse, AST export for CLI

## Completed
- [x] Project initialization
- [x] Inline formatter behavior on hoedown checked and recorded (intent doc, "Dropped features" / "Checked 2026-10-09")
- [x] Underline setting removed; underline is `<u>…</u>` (2026-10-09)

## Notes
- Principle: standard Markdown (CommonMark + GFM + footnotes + front matter) always on; extended features (highlight, superscript, autolink, smart punctuation, math, `[TOC]`, hard wrap, Graphviz) opt-in, off by default, keeping existing defaults keys.
- Byte-identical output with the original MacDown is intentionally dropped (overrides CLAUDE.md's current rule once this project lands); differences go in the README.
- Parser: cmark-gfm used directly (Decision 10, 2026-10-09); resolves Open Questions 1 and 2.
- Corpus: generated fixtures plus `help.md` only; never real user documents or other docs (decided 2026-10-09).
- `pmh_parser.c` is generated; never hand-edit it while it still exists.
- Release notes must call out: strikethrough/task lists/front matter now always on, Quote dropped, new editing defaults for new installs.
- `.ralph/` is gitignored; plan state is local.

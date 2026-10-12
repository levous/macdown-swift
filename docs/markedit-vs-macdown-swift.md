# MarkEdit vs. MacDown-swift: scroll sync and editor highlighting

A comparison of how [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) and this
port handle two things: keeping the preview in step with the editor, and
syntax-highlighting the source pane. It covers why MarkEdit's preview scroll looks
smooth and why its source pane never shows unstyled text, then what it would take
to get both here.

Sources read (2026-10-12):

- MarkEdit `083df01e` (`../MarkEdit`), its CodeMirror-based editor (`CoreEditor/`).
- MarkEdit-preview `ff523d2` (release 1.13.0), from
  <https://github.com/MarkEdit-app/MarkEdit-preview>. MarkEdit itself has no
  side-by-side preview. The preview pane and its scroll sync are this separate
  extension script, which MarkEdit loads into the editor's web view.
  `CoreEditor/src/modules/preview` in MarkEdit is something else: popover
  previews of a single Mermaid, KaTeX or table block.
- MacDown-swift at `a9de35d` (Release 1.2).

**Status (2026-10-12):** the highlighting design in section 2 is implemented;
see "Highlight before drawing, then the rest when idle" in
[ARCHITECTURE.md](ARCHITECTURE.md#decisions). Section 2 describes the code as
it was at `a9de35d`. The smooth-scroll design in section 1 is not
implemented yet.

## Architecture in one paragraph each

**MarkEdit.** The whole editor is one `WKWebView` running CodeMirror 6, with the
Lezer Markdown grammar for parsing and highlighting. The preview extension adds a
`<div>` next to CodeMirror's DOM in the **same document**
(`MarkEdit-preview/src/view.ts:22`, `:65`) and splits the window with
`split-grid`. Markdown is rendered with markdown-it, in the same JS context, 500 ms
after the last edit (`main.ts:112`), and the result is set as the div's
`innerHTML` (`view.ts:214`). Both panes are DOM in one page, so the code that
syncs them reads both layouts directly and synchronously.

**MacDown-swift.** The editor is a native `NSTextView` (TextKit 1,
`EditorTextView`). The preview is a **separate** `WKWebView` in its own WebContent
process. The Markdown is parsed off the main actor (cmark-gfm,
`MarkdownDocumentModel`). One parse produces the preview HTML and the editor's
highlight spans (`HighlightMapper`). Talking to the preview means
`evaluateJavaScript` and script message handlers, so every round trip is
asynchronous IPC.

The two differences below follow mostly from this split.

---

## 1. Scroll sync

### MarkEdit (MarkEdit-preview `src/scroll.ts`)

- **Direction: editor → preview only.** `startObserving(getEditPane(),
  getPreviewPane())` (`main.ts:136`) is the only listener. Nothing listens to the
  preview's scrolling, so scrolling the preview never moves the editor. The other
  call to `syncScrollProgress` (`view.ts:223`) re-aligns the preview after a
  re-render.
- **When: once, after the editor stops.** It listens for `scrollend` on
  CodeMirror's `scrollDOM`. Without `scrollend`, it falls back to `scroll` plus a
  100 ms debounce (`scroll.ts:35-45`). It never syncs during a scroll. It also
  ignores "phantom" scroll events where `scrollTop` moved less than 0.5 px and
  the selection didn't change.
- **Mapping: source line + fraction → block.** markdown-it's renderer rules put
  `data-line-from` / `data-line-to` on every block token (`render.ts:229-236`). The
  editor side calls `lineBlockAtHeight(scrollTop)` to get the top visible line and
  how far into that line's box the viewport starts (`progress`, 0-1). The preview
  then:
  1. finds the block whose line range contains that line, and scrolls to
     `blockTop + blockHeight × relativeProgress`, where `relativeProgress` spreads
     the line over the block's lines;
  2. otherwise interpolates between the closest blocks before and after it, in
     the gap between them (blank lines, unmarked content);
  3. otherwise snaps to the start or the end.
  This aligns the **top** of both panes. There is no "focus line" and no taper at
  the ends.
- **Smoothness: one CSS smooth scroll.** `scrollToPosition` calls
  `element.scrollTo({ top, behavior: 'smooth' })` (`shared/utils.ts:68-74`), and
  the browser animates that single jump. After a re-render it uses
  `behavior: 'instant'`.

So the smoothness comes from the timing as much as the easing. The preview stays
still while you scroll, then glides once to the new spot. It never has to follow
a moving target, so nothing can stutter. The cost is that the preview is out of
step for the whole scroll, and there is no reverse sync.

### MacDown-swift (`Document/ScrollSync.swift`, `DocumentController.swift:929-1060`)

- **Direction: both ways.** `scrollLeader` records which pane the user scrolled
  last, and the other pane follows (`syncScrollers`, `DocumentController.swift:985`).
- **When: every frame, during the scroll.** `editorBoundsDidChange` (`:757`) runs on
  every `NSView.boundsDidChangeNotification` of the editor's clip view and calls
  `syncScrollers` straight away. In the other direction, the page's scroll
  listener posts `window.scrollY` once per animation frame
  (`PreviewController.scrollReporterScript`), and `previewDidScroll` (`:1014`)
  moves the editor's clip view.
- **Mapping: anchors → piecewise-linear map, aligned at a focus line.** With
  cmark-gfm, every preview block carries `data-source-line`, and those lines'
  positions in the editor are measured with the layout manager
  (`updateEditorAnchors`, `:945`). `ScrollMap` pairs them and interpolates
  between pairs. `ScrollGeometry.focus(at:)` aligns the panes at the middle of the
  visible area, tapering to the top and bottom edges within the first and last
  screen, so both panes reach their ends together. This is more careful than
  MarkEdit's top-line mapping: pane ends always line up, and tall images or
  unequal widths stay aligned.
- **Smoothness: none, by design.** `PreviewController.scroll(to:)` (`:253`)
  evaluates `window.scrollTo(0, y)` and jumps instantly. Each jump is an async
  call into another process, so the preview runs a frame or more behind the
  editor, and it moves in whatever steps the IPC delivers. The map is linear
  between anchors, so the preview's speed also changes abruptly at each anchor (a
  tall image between two paragraphs makes the preview speed up, then slow down).
  That stepping and the speed kinks are what reads as "not smooth". MarkEdit has
  neither problem, because it only moves once.
- **Echo suppression is time-based.** The preview's own scroll events, caused by
  `syncScrollers`, are told apart from the user's by `previewScrollTarget`: an
  event is ignored if it's within 1 px of the last target **or less than 0.25 s
  after it was set** (`:1016-1021`).

### Can MacDown-swift adopt the smooth scroll? Yes, but not in one line

Changing `scroll(to:)` to `window.scrollTo({ top: y, behavior: 'smooth' })` would
break three things:

1. **Per-frame restarts.** `syncScrollers` runs on every editor bounds change.
   Each smooth `scrollTo` cancels the previous animation and starts a new one.
   The preview would visibly lag and stutter behind the editor, which is worse
   than now. MarkEdit avoids this only because it scrolls once, after
   `scrollend`.
2. **Echo suppression.** A smooth scroll reports intermediate `scrollY` values.
   An animation longer than 0.25 s produces reports that are neither within 1 px
   of the target nor inside the time window. `previewDidScroll` would take them
   for the user scrolling the preview, flip `scrollLeader` to `.preview`, and yank
   the editor back towards where the animation happens to be.
3. **Tests.** WebKit doesn't run animation frames in the off-screen test windows
   (see CLAUDE.md). `DocumentControllerTests` checks `window.scrollY` right after
   a sync (`DocumentControllerTests.swift:175`, `:233`, `:261`), and a smooth
   scroll would never get there.

### Recommended design

Keep the live, bidirectional sync (it's the better behavior) and smooth out how
the preview gets there, without copying MarkEdit's "sync on stop" model:

1. **Ease toward a target in the page, not in Swift.** Add a small script to the
   preview, `window.__macdownScrollTo(y, animate)`. It stores the target and runs
   a `requestAnimationFrame` loop that moves `scrollY` part of the way there each
   frame (exponential approach: `y += (target - y) * k` with `k` around 0.25-0.35,
   snapping when within 0.5 px). A new target from Swift just replaces the stored
   one and doesn't restart anything, so a stream of per-frame targets during a
   live scroll becomes one continuous motion. That also smooths out the IPC steps
   and the speed changes at anchors. `scroll(to:)` calls it in place of
   `window.scrollTo`.
2. **Make echo suppression state-based.** While the easing loop runs, the scroll
   reporter doesn't post `MacDownScroll` (or tags the message as programmatic).
   It posts again once the loop has settled. Any user input on the preview
   (`wheel`, `keydown`, `mousedown` on the scrollbar) cancels the loop at once,
   so the user always wins and the leader switches cleanly. The time window in
   `previewDidScroll` can then go.
3. **Instant where animating would be wrong:**
   - after a page load or body swap (`render()`, `restoreScrollPosition`),
     matching MarkEdit's `behavior: 'instant'` after re-render;
   - when `prefers-reduced-motion` is on (MarkEdit's `CoreEditor` checks
     `isMotionReduced` for its own animations);
   - in tests, through a `PreviewController` flag (for example
     `animatesScrolling`, default `true`, set to `false` by the live test suites),
     so `window.scrollY` is final as soon as `scroll(to:)` returns.
4. **Preview → editor (optional).** The editor already follows the preview's
   per-frame reports with native clip-view scrolling, which looks fine. If it
   ever needs easing, `NSClipView.animator().setBoundsOrigin(_:)` inside an
   `NSAnimationContext` group does it. That path has its own guard,
   `shouldHandleBoundsChange`, so it doesn't feed back.

A simpler alternative, closer to MarkEdit: sync instantly during a live scroll
and do one smooth `scrollTo` on `didEndLiveScrollNotification` to correct the
remaining offset. That's less code, but the preview's motion during a scroll
stays exactly as it is now, so it doesn't fix what's been noticed. If it's used,
first check that `'onscrollend' in window` is true in the app's `WKWebView`
(one `evaluateJavaScript`). Don't assume it.

---

## 2. Source-pane parsing and highlighting

### MarkEdit: CodeMirror 6 + Lezer

- **Parsing is incremental and runs on the main thread, within a time budget.**
  `@codemirror/lang-markdown` (`CoreEditor/src/extensions.ts:184`) keeps a Lezer
  syntax tree. After an edit, the parser reuses the unchanged parts of the old
  tree and reparses only the region around the change. It parses at least as far
  as the viewport synchronously, in the same transaction, and finishes the rest of
  the document in short time slices while the editor is idle. (The local checkout
  has no `node_modules`, so the exact budget constants aren't quoted here.)
- **Highlighting is decorations, computed for the viewport during the view
  update.** `syntaxHighlighting(...)` (`CoreEditor/src/styling/builder.ts:285`,
  `styling/markdown.ts:15-16`) is a view plugin. In each view update, scrolling
  included, it walks the tree over the visible ranges and produces mark
  decorations: CSS classes on spans.
- **Only the viewport (plus a margin) exists in the DOM.** CodeMirror renders the
  lines in and just around the viewport. When you scroll, the newly revealed
  lines are created **with their decorations already attached**, in the same
  frame. Styled text is the only kind of text CodeMirror ever draws, so there is
  no window where unstyled text shows.
- Everything else MarkEdit styles (headings, links, tasks, code, tables) is more
  view plugins or decorations on the same tree (`styling/nodes/*`).

### MacDown-swift: whole-document parse + visible-range attribute application

- **Parsing is whole-document, off the main actor.** Every edit runs a full
  cmark-gfm parse in a detached task (`Renderer.parse`). `HighlightMapper` turns
  the tree into spans keyed by PEG element types, and `DocumentController` hands
  them to `MarkdownHighlighter.update(_:)` (`highlightFromModel`,
  `DocumentController.swift:618`). This is fast and keeps typing responsive, but
  text you've just typed keeps its old (or no) styling until the parse finishes.
  That's a separate, much smaller effect from the scroll delay below.
- **Highlighting is `NSTextStorage` attributes, applied to the visible range
  only.** `applyVisibleRangeHighlighting` (`MarkdownHighlighter.swift:368`) gets
  the visible glyph range from the layout manager. `applyHighlighting` (`:313`)
  then, inside one `beginEditing/endEditing`, clears all attributes in that range
  (fonts, colors, links, underline) and re-adds every style whose spans overlap
  it.
- **Text revealed by scrolling waits 100 ms after the scroll stops. This is the
  delay you see.** `textViewDidScroll` (`MarkdownHighlighter.swift:510`) runs on
  every clip-view bounds change. It cancels the pending work item and schedules a
  new one 0.1 s later:

  ```swift
  scrollWorkItem?.cancel()
  ...
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
  ```

  During a continuous scroll (trackpad, momentum), bounds change every frame, so
  the work item is pushed back again and again and **never runs until scrolling
  pauses for 100 ms**. All the text scrolled into view in the meantime is drawn
  with the base font and color, then restyled at once when you stop.

  **This is a regression against the original, not inherited behavior.** The
  original MacDown's `HGMarkdownHighlighter.m` (`textViewDidScroll:`,
  `Dependency/peg-markdown-highlight/HGMarkdownHighlighter.m:418-431`) calls
  `cancelAllOperations` on a serial `NSOperationQueue`, then adds an operation
  that does `usleep(0.1 s)` and highlights on the main queue.
  `cancelAllOperations` can't stop an operation that's already running, so the
  one sleeping finishes and highlights. The original therefore restyled about
  every 100 ms *during* a scroll (a throttle). The port's
  `DispatchWorkItem.cancel()` cancels the pending item before it runs, which
  makes it a trailing debounce that never fires until scrolling stops. A
  one-line partial fix that restores the original behavior: don't cancel a
  pending item, only schedule one when none is pending (throttle). Text would
  still appear unstyled for up to 100 ms, though, so the design below is still
  the real fix.

### Removing the delay

Deleting the debounce alone isn't enough. `applyHighlighting` clears and
reapplies the **whole** visible range every time, inside a storage edit. Each of
those edits runs `processEditing`, invalidates layout and glyphs for the range,
and reaches `DocumentController.editorStorageDidProcessEditing(attributesOnly:)`
(`:1038`), which resets `editorAnchorsKey`. Doing all that every frame for a
whole screen of text is a lot of churn, and it would show up as dropped frames
in long documents.

Recommended design, which gets close to CodeMirror's "styled before it's drawn"
without rewriting the highlighter:

1. **Track what's already highlighted.** `MarkdownHighlighter` keeps an
   `IndexSet`, `highlightedRanges`, of character ranges styled with the current
   `cachedElements`. `update(_:)`, `applyStyles(fromStylesheet:)`,
   `clearHighlighting()` and `deactivate()` reset it. Text edits shift and
   invalidate it; the simplest correct rule is to clear it on each new parse
   result, since `update(_:)` follows every edit anyway.
2. **Highlight newly revealed text synchronously, with overscan.**
   `textViewDidScroll` drops the work item. It computes the visible character
   range grown by about one screen above and below, extended to whole lines,
   subtracts `highlightedRanges`, and highlights only what's left. Most frames
   have nothing left to do. The occasional frame that does styles about a screen
   of text, and does it ahead of time, so text arrives on screen already styled.
3. **Fill in the rest of the document when idle.** After `update(_:)` has styled
   the viewport, highlight the remaining ranges in chunks (for example 20-50 KB
   of text per main-queue turn, or per `RunLoop` idle). Stop when a newer parse
   arrives (`parseGeneration`). Once that finishes, the whole document is styled
   and scrolling has nothing to do, which is how CodeMirror behaves once its
   background parse completes.
4. **Batch the storage edits.** Group each chunk's attribute changes in one
   `beginEditing/endEditing`, as now. Consider skipping `clearHighlighting` for
   ranges that were never styled, since that work is wasted on fresh text.

Caveats to check when implementing:

- **Themes that change font size** (headings in some `.style` themes) change line
  heights when they're applied. Styling text *above* the viewport moves the text
  in view, because `NSScrollView` has no scroll anchoring. Overscan below is
  harmless. For overscan above, either keep the visible text in place by
  adjusting the clip view's origin by the height change, or highlight above only
  in the idle pass, when it's further away. Today's code has the same jump when
  you scroll up into unstyled headings; it's just delayed.
- **Scroll sync anchors.** `updateEditorAnchors` measures line positions with the
  layout manager. Restyling during a live scroll is ignored there
  (`inLiveScroll`), and the idle pass sends attributes-only edits that trigger
  `editorStorageDidProcessEditing`'s re-sync. That's correct, but it should stay
  coalesced (`editorLayoutSyncScheduled` already does this) so the idle pass
  doesn't re-sync per chunk.
- **Large documents.** Measure `applyHighlighting` over a chunk with the debug
  report (`MACDOWN_DEBUG_REPORT`) or Instruments before choosing the chunk size.

A bigger alternative is to move to TextKit 2 and style through
`NSTextContentStorage` / rendering attributes on `NSTextLayoutManager`, which
asks only for what's being laid out, as CodeMirror does. That's a large change
to `EditorTextView` and every layout-manager call (scroll anchors, `scrollsPastEnd`),
and not needed to remove the visible delay.

---

## Summary

| | MarkEdit (+ MarkEdit-preview) | MacDown-swift |
| --- | --- | --- |
| Editor | CodeMirror 6 in a WKWebView | NSTextView (TextKit 1) |
| Preview | `<div>` in the same page | Separate WKWebView (IPC) |
| Preview render | markdown-it, 500 ms after the last edit, `innerHTML` | cmark-gfm off-main, body swap or page load |
| Sync direction | Editor → preview only | Both, last-scrolled pane leads |
| Sync timing | Once, on `scrollend` | Every frame during the scroll |
| Mapping | Top line + fraction → `data-line-from/to` block, interpolated | Source-line anchors → piecewise-linear map, focus line with tapered ends |
| Preview motion | One CSS smooth scroll (`behavior: 'smooth'`) | Instant `window.scrollTo` per frame |
| Source parse | Lezer, incremental, viewport first, rest when idle | cmark-gfm, whole document, detached task |
| Source styling | Decorations, built with the visible lines in the same frame | Attributes on the visible range, 100 ms after scrolling stops |
| Unstyled text visible? | Never | During any continuous scroll |

**Recommendations, in order of payoff vs. effort:**

1. **Highlighting delay:** the quick fix is to throttle instead of debounce,
   which restores the original MacDown's behavior. The full fix is to drop the
   100 ms delay in favor of synchronous,
   incremental, overscanned highlighting with highlighted-range tracking, plus an
   idle pass that styles the whole document. This change stays inside
   `MarkdownHighlighter`, plus a little in `DocumentController` for the sync
   coalescing.
2. **Smooth preview scrolling:** an in-page easing loop that follows a moving
   target, state-based echo suppression in place of the 0.25 s window, and
   instant scrolling after loads, with reduced motion and in tests. This keeps
   MacDown-swift's two-way, live sync, which is already better than MarkEdit's
   one-way sync on stop.

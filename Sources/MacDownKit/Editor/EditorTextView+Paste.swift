//
//  EditorTextView+Paste.swift
//  MacDown
//
//  Pasting formatted text as Markdown (paste intent).
//

import AppKit

extension EditorTextView {
    // MARK: - Paste

    /// Paste, Services and text dropped from other apps all read here:
    /// formatted text becomes Markdown and image data an image;
    /// anything else is read as usual.
    public override func readSelection(from pasteboard: NSPasteboard,
                                       type: NSPasteboard.PasteboardType) -> Bool {
        if !pastesPlainText, pasteConverted(from: pasteboard) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    /// AppKit only reads the types below on to the method above, so image
    /// data alone would go nowhere.
    public override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if !pastesPlainText, pasteConverted(from: pasteboard) { return true }
        return super.readSelection(from: pasteboard)
    }

    /// Formatted text and image data are readable too, so Paste is enabled
    /// for them and they can be dropped.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.html, PasteboardContent.webArchive, .rtf, .rtfd,
                                         .png, PasteboardContent.jpeg, .tiff]
            .filter { !super.readablePasteboardTypes.contains($0) }
    }

    /// Paste and Match Style: always the plain text.
    public override func pasteAsPlainText(_ sender: Any?) {
        pastesPlainText = true
        defer { pastesPlainText = false }
        super.pasteAsPlainText(sender)
    }

    /// Edit ▸ Paste as Markdown: converts even with the setting off.
    @objc public func pasteAsMarkdown(_ sender: Any?) {
        if !pasteConverted(from: .general, convertsFormatting: true) {
            super.paste(sender)
        }
    }

    /// Inserts the Markdown for `pasteboard`'s formatted text, or its
    /// image, in place of the selection, as one undoable change. False when
    /// there's nothing to convert, so the caller pastes as usual: plain
    /// text, code, a paste into a code block, or formatted text when not
    /// converting it (images are pasted either way).
    @discardableResult
    func pasteConverted(from pasteboard: NSPasteboard, convertsFormatting: Bool? = nil) -> Bool {
        let selection = selectedRange()
        guard !isInCodeBlock(selection.location),
              let content = PasteboardContent.read(from: pasteboard)
        else { return false }
        switch content {
        case .image(let data, let mime):
            dismissPlainTextButton()
            insertPasted(ImageMarkup.dataURI(data, mime: mime), isInline: true)
        case .html(let html, let baseURL):
            guard convertsFormatting ?? convertsPastedFormatting else { return false }
            var options = pasteOptions
            options.baseURL = baseURL
            guard let result = HTMLToMarkdown(options: options).convert(html), !result.isCode
            else { return false }
            dismissPlainTextButton()
            let inserted = insertPasted(result.markdown, isInline: result.isInline)
            if let plain = pasteboard.string(forType: .string),
               plain.trimmingCharacters(in: .whitespacesAndNewlines)
                != result.markdown.trimmingCharacters(in: .whitespacesAndNewlines) {
                showPlainTextButton(replacing: inserted, with: plain)
            }
        }
        return true
    }

    /// Inserts pasted Markdown as its own undo step (not merged with the
    /// typing before it), through the usual text-change path so the
    /// document sees it like typing. Blocks are set off from the
    /// text around them by blank lines.
    /// The range of the inserted text.
    @discardableResult
    private func insertPasted(_ markdown: String, isInline: Bool) -> NSRange {
        let range = selectedRange()
        var text = markdown
        if !isInline {
            let padding = Self.blockPadding(around: range, in: string as NSString)
            text = padding.before + text + padding.after
        }
        breakUndoCoalescing()
        insertText(text, replacementRange: range)
        breakUndoCoalescing()
        return NSRange(location: range.location, length: (text as NSString).length)
    }

    // MARK: - Paste as Plain Text

    /// Whether a background is dark enough to want light controls on it.
    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
    }

    /// Shows a button just below `range`, what a converted paste inserted,
    /// that puts `plainText` there instead. It never takes focus,
    /// so typing goes on in the editor.
    func showPlainTextButton(replacing range: NSRange, with plainText: String) {
        dismissPlainTextButton()
        let title = String(localized: "Paste as Plain Text")
        let button = NSButton(title: title, target: self, action: #selector(pastePlainTextInstead(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.refusesFirstResponder = true
        // Editor themes set their own background, whatever the system's
        // appearance, so a light-mode button can be black on a dark theme.
        button.appearance = NSAppearance(named: Self.isDark(backgroundColor) ? .darkAqua : .aqua)
        button.setAccessibilityLabel(title)
        button.sizeToFit()
        addSubview(button)
        plainTextButton = button
        pastedPlainText = (range, (string as NSString).substring(with: range), plainText)
        positionPlainTextButton()
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    /// Puts the button under the last line of the pasted text.
    func positionPlainTextButton() {
        guard let button = plainTextButton, let pasted = pastedPlainText,
              let layoutManager, let textContainer
        else { return }
        let text = string as NSString
        var end = min(NSMaxRange(pasted.range), text.length)
        while end > pasted.range.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        let index = max(pasted.range.location, end - 1)
        var lineRect = NSRect.zero
        if index < text.length {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
            lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        button.setFrameOrigin(NSPoint(x: textContainerOrigin.x + lineRect.minX + textContainer.lineFragmentPadding,
                                      y: textContainerOrigin.y + lineRect.maxY + 2))
    }

    /// Replaces the converted paste with the plain text, as its own undo
    /// step, so Undo brings back the Markdown.
    @objc func pastePlainTextInstead(_ sender: Any?) {
        guard let pasted = pastedPlainText else { return }
        dismissPlainTextButton()
        let text = string as NSString
        guard NSMaxRange(pasted.range) <= text.length, text.substring(with: pasted.range) == pasted.inserted
        else { return }
        breakUndoCoalescing()
        insertText(pasted.text, replacementRange: pasted.range)
        breakUndoCoalescing()
    }

    /// Removes the button, and lets go of the pasted range and plain text.
    /// It stays until then: there's no timeout.
    func dismissPlainTextButton() {
        guard let button = plainTextButton else { return }
        button.removeFromSuperview()
        plainTextButton = nil
        pastedPlainText = nil
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    }

    /// Escape (`cancelOperation:`, which a text view handles as a command)
    /// dismisses the button; otherwise it does what it always does.
    public override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)), plainTextButton != nil {
            dismissPlainTextButton()
        } else {
            super.doCommand(by: selector)
        }
    }

    /// Moving the selection out of the pasted text dismisses the button.
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                           stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard let pasted = pastedPlainText else { return }
        let inside = ranges.allSatisfy { value in
            let range = value.rangeValue
            return range.location >= pasted.range.location && NSMaxRange(range) <= NSMaxRange(pasted.range)
        }
        if !inside { dismissPlainTextButton() }
    }

    /// Scrolling the button out of view dismisses it.
    @objc private func editorDidScroll(_ notification: Notification) {
        guard let button = plainTextButton else { return }
        if !visibleRect.intersects(button.frame) { dismissPlainTextButton() }
    }

    /// What to add around pasted blocks (ending in a newline) at `range` so
    /// they're separated from the text before and after by a blank line.
    static func blockPadding(around range: NSRange, in text: NSString) -> (before: String, after: String) {
        var before = ""
        if range.location > 0 {
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            if range.location > lineStart {
                before = "\n\n"
            } else {
                let previous = text.lineRange(for: NSRange(location: range.location - 1, length: 0))
                if !text.substring(with: previous).allSatisfy(\.isWhitespace) { before = "\n" }
            }
        }
        let end = NSMaxRange(range)
        let after = end < text.length && !CharacterSet.newlines.contains(UnicodeScalar(text.character(at: end)) ?? " ")
            ? "\n" : ""
        return (before, after)
    }

    // MARK: - Code blocks

    /// Whether `location` is inside a fenced or indented code block:
    /// by scanning the fences above it, which also works when the latest
    /// parse is behind the text, or, for indented code, from the parse.
    func isInCodeBlock(_ location: Int) -> Bool {
        if isInFencedBlock(location) { return true }
        guard let documentBlocks, documentBlocks.source == string else { return false }
        return documentBlocks.blocks.contains { block in
            block.kind == .codeBlock && NSLocationInRange(location, block.range)
        }
    }

    /// Whether `location` is after an opening fence that isn't closed
    /// before it. A closing fence uses the opening's character, at least as
    /// many times, and nothing after (CommonMark).
    func isInFencedBlock(_ location: Int) -> Bool {
        let text = string as NSString
        var open: (character: Character, count: Int)?
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            // The caret's own line: inside if a fence is open, unless this
            // line closes it.
            let isCaretLine = location < NSMaxRange(lineRange)
            let line = text.substring(with: lineRange)
            if let fence = Self.fence(line) {
                if let current = open {
                    if fence.character == current.character, fence.count >= current.count, fence.isBare {
                        if isCaretLine { return false }
                        open = nil
                    }
                } else {
                    if isCaretLine { return false }
                    open = (fence.character, fence.count)
                }
            }
            if isCaretLine { return open != nil }
            lineStart = NSMaxRange(lineRange)
        }
        return open != nil
    }

    /// A fence line: up to three spaces, then three or more backticks or
    /// tildes. `isBare` when nothing but spaces follows.
    static func fence(_ line: String) -> (character: Character, count: Int, isBare: Bool)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let count = rest.prefix { $0 == character }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count)
        // A backtick fence's info string can't contain backticks.
        if character == "`", info.contains("`") { return nil }
        return (character, count, info.allSatisfy(\.isWhitespace))
    }
}

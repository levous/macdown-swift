//
//  EditorTextView+Paste.swift
//  MacDown
//
//  Pasting formatted text as Markdown (paste intent).
//

import AppKit

extension EditorTextView {
    // MARK: - Paste

    /// Formatted text is pasted as Markdown and image data as an image;
    /// anything else as usual. Paste and Match Style (`pasteAsPlainText:`)
    /// reads the plain text without coming here (FR-4).
    public override func paste(_ sender: Any?) {
        if !pasteConverted(from: .general) {
            super.paste(sender)
        }
    }

    /// Edit ▸ Paste as Markdown: converts even with the setting off (FR-28).
    @objc public func pasteAsMarkdown(_ sender: Any?) {
        if !pasteConverted(from: .general, convertsFormatting: true) {
            super.paste(sender)
        }
    }

    /// Inserts the Markdown for `pasteboard`'s formatted text, or its
    /// image, in place of the selection, as one undoable change. False when
    /// there's nothing to convert, so the caller pastes as usual: plain
    /// text, code (FR-6), a paste into a code block (FR-5), or formatted
    /// text when not converting it (FR-27; images are pasted anyway, FR-34).
    @discardableResult
    func pasteConverted(from pasteboard: NSPasteboard, convertsFormatting: Bool? = nil) -> Bool {
        let selection = selectedRange()
        guard !isInCodeBlock(selection.location),
              let content = PasteboardContent.read(from: pasteboard)
        else { return false }
        switch content {
        case .image(let data, let mime):
            insertPasted(ImageMarkup.dataURI(data, mime: mime), isInline: true)
        case .html(let html, let baseURL):
            guard convertsFormatting ?? convertsPastedFormatting else { return false }
            var options = pasteOptions
            options.baseURL = baseURL
            guard let result = HTMLToMarkdown(options: options).convert(html), !result.isCode
            else { return false }
            insertPasted(result.markdown, isInline: result.isInline)
        }
        return true
    }

    /// Inserts pasted Markdown as its own undo step (not merged with the
    /// typing before it), through the usual text-change path so the
    /// document sees it like typing (FR-7). Blocks are set off from the
    /// text around them by blank lines.
    private func insertPasted(_ markdown: String, isInline: Bool) {
        let range = selectedRange()
        var text = markdown
        if !isInline {
            let padding = Self.blockPadding(around: range, in: string as NSString)
            text = padding.before + text + padding.after
        }
        breakUndoCoalescing()
        insertText(text, replacementRange: range)
        breakUndoCoalescing()
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

    /// Whether `location` is inside a fenced or indented code block (FR-5):
    /// from the latest parse, or, when that's behind the text, by scanning
    /// the fences above it.
    func isInCodeBlock(_ location: Int) -> Bool {
        if let documentBlocks, documentBlocks.source == string {
            let length = (string as NSString).length
            return documentBlocks.blocks.contains { block in
                // An unclosed fence runs to the end of the document.
                block.kind == .codeBlock && (NSLocationInRange(location, block.range)
                    || (location == length && NSMaxRange(block.range) == length))
            }
        }
        return isInFencedBlock(location)
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

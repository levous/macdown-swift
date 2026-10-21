//
//  EditorTextView+Paste.swift
//  MacDown
//
//  Pasting formatted text as Markdown (paste intent).
//

import AppKit

extension EditorTextView {
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

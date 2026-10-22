//
//  TaskListToggle.swift
//  MacDown
//
//  Checks and unchecks task list items in the Markdown when their checkbox
//  is clicked in the preview ("Enable checkbox toggling"). New in the Swift
//  port: the original's preview checkboxes were always disabled.
//

import AppKit

enum TaskListToggle {
    /// A task list item's line: block quote markers and indentation, one or
    /// more list markers (`- - [ ]` nests a list on the same line), then the
    /// checkbox, followed by a space or the end of the line.
    private static let itemPattern = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>)*[ \t]*(?:(?:[-+*]|\d{1,9}[.)])[ \t]+)+\[([ xX])\](?=[ \t]|$)"#)

    /// The range (UTF-16) of the character between the brackets of the task
    /// list item on a 1-based line, or nil if the line isn't one (it may
    /// have changed since the preview was rendered).
    static func checkboxRange(in text: String, line: Int) -> NSRange? {
        let index = LineIndex(text)
        let content = text as NSString
        guard let start = index.utf16Offset(line: line, column: 1) else { return nil }
        let end = line < index.lineCount
            ? index.utf16Offset(line: line + 1, column: 1) ?? content.length
            : content.length
        let lineRange = NSRange(location: start, length: end - start)
        guard let match = itemPattern.firstMatch(in: text, options: [], range: lineRange)
        else { return nil }
        return match.range(at: 1)
    }
}

extension NSTextView {
    /// Checks or unchecks the task list item on a 1-based line, as an
    /// undoable edit. Returns whether the line is a task list item.
    @discardableResult
    func setTaskListItem(atLine line: Int, checked: Bool) -> Bool {
        guard let range = TaskListToggle.checkboxRange(in: string, line: line)
        else { return false }
        let isChecked = (string as NSString).substring(with: range) != " "
        guard isChecked != checked else { return true }
        let replacement = checked ? "x" : " "
        // A hidden editor isn't editable (preview only), which would refuse
        // the change.
        let wasEditable = isEditable
        isEditable = true
        defer { isEditable = wasEditable }
        if shouldChangeText(in: range, replacementString: replacement) {
            replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        return true
    }
}

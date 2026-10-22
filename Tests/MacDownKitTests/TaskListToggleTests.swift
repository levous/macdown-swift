//
//  TaskListToggleTests.swift
//  MacDownKitTests
//

import AppKit
import Testing
@testable import MacDownKit

@MainActor @Suite struct TaskListToggleTests {
    func marker(_ text: String, line: Int) -> String? {
        TaskListToggle.checkboxRange(in: text, line: line)
            .map { (text as NSString).substring(with: $0) }
    }

    @Test(arguments: [
        ("- [ ] task", " "), ("* [x] task", "x"), ("+ [X] task", "X"),
        ("1. [ ] task", " "), ("12) [x] task", "x"), ("  - [ ] nested", " "),
        ("\t* [x] tab-nested", "x"), ("> - [ ] quoted", " "), ("> > 1. [x] deep", "x"),
        ("- - [ ] same line", " "), ("- [ ]", " "),
    ])
    func findsTheCheckbox(line: String, expected: String) {
        #expect(marker(line, line: 1) == expected)
    }

    @Test(arguments: ["- task", "[ ] not a list", "- [y] task", "- [ ]task", "-[ ] task",
                      "text - [ ] task", ""])
    func ignoresOtherLines(line: String) {
        #expect(marker(line, line: 1) == nil)
    }

    @Test func usesTheGivenLine() {
        let text = "# Title\r\n\r\n- [ ] é one\n- [x] two"
        #expect(TaskListToggle.checkboxRange(in: text, line: 3)
                == NSRange(location: 14, length: 1))
        #expect(marker(text, line: 4) == "x")
        #expect(marker(text, line: 1) == nil)
        #expect(marker(text, line: 5) == nil)
        #expect(marker(text, line: 0) == nil)
    }

    @Test func setsTheItemAsAnEdit() {
        let textView = NSTextView()
        textView.allowsUndo = true
        textView.string = "- [ ] one\n- [x] two\n"
        #expect(textView.setTaskListItem(atLine: 1, checked: true))
        #expect(textView.setTaskListItem(atLine: 2, checked: false))
        #expect(textView.setTaskListItem(atLine: 2, checked: false))
        #expect(textView.string == "- [x] one\n- [ ] two\n")
        #expect(!textView.setTaskListItem(atLine: 3, checked: true))
        // The editor isn't editable while it's hidden (preview only).
        textView.isEditable = false
        #expect(textView.setTaskListItem(atLine: 1, checked: false))
        #expect(textView.string == "- [ ] one\n- [ ] two\n")
        #expect(!textView.isEditable)
    }

    /// The preview's source lines, which clicks report, count front matter.
    @Test func previewLinesMatchTheSourceAfterFrontMatter() {
        let text = "---\ntitle: Tasks\n---\n\n- [ ] one\n"
        var options = MarkdownDocumentModel.Options(Preferences.shared.renderSettings.parse)
        options.sourceLines = true
        let model = MarkdownDocumentModel(text, options: options)
        #expect(model.body.contains(#"<li data-source-line="5" class="task-list-item">"#))
        #expect(marker(text, line: 5) == " ")
    }
}

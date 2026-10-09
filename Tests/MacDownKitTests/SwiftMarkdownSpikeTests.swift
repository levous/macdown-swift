//
//  SwiftMarkdownSpikeTests.swift
//  MacDownKitTests
//
//  Phase 0 of the swift-markdown migration: checks what swift-markdown
//  provides before the new engine is built on it. The answers are recorded
//  in docs/intents/swift-markdown-migration.md ("Decisions").
//

import Markdown
import Testing

@Suite struct SwiftMarkdownSpikeTests {
    @Test func parsesInADetachedTask() async {
        let summary = await Task.detached {
            let document = Document(parsing: "# Title\n\nSome *text*.\n")
            return (document.childCount, document.child(at: 0) is Heading)
        }.value
        #expect(summary.0 == 2)
        #expect(summary.1)
    }
}

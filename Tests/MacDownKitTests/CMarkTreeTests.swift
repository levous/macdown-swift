//
//  CMarkTreeTests.swift
//  MacDownKitTests
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct CMarkTreeTests {
    func kinds(_ node: CMarkNode) -> [CMarkNode.Kind] {
        [node.kind] + node.children.flatMap(kinds)
    }

    @Test func parsesStandardMarkdown() {
        let tree = CMarkTree("# T\n\n- [x] done\n\n| a |\n|---|\n| 1 |\n\n~~gone~~ `code` a[^1]\n\n[^1]: Note.\n")
        let all = kinds(tree.root)
        for kind: CMarkNode.Kind in [.heading, .taskItem, .table, .tableHeader, .tableRow, .tableCell,
                                     .strikethrough, .code, .footnoteReference, .footnoteDefinition] {
            #expect(all.contains(kind), "no \(kind)")
        }
        let task = tree.root.children[1].children[0]
        #expect(task.kind == .taskItem && task.isChecked)
    }

    /// Positions follow swift-markdown's convention (end exclusive, code
    /// spans with their backticks), which the model was written against.
    @Test func positions() throws {
        let tree = CMarkTree("# Title\n\nSay ``a`b`` now.\n")
        let heading = try #require(tree.root.children.first?.range)
        #expect(heading.start == .init(line: 1, column: 1) && heading.end == .init(line: 1, column: 8))
        let code = try #require(tree.root.children[1].children.first { $0.kind == .code }?.range)
        #expect(code.start == .init(line: 3, column: 5) && code.end == .init(line: 3, column: 12))
    }

    @Test func autolinkAndSmartPunctuationOnlyWhenOn() {
        func links(_ tree: CMarkTree) -> Int { kinds(tree.root).filter { $0 == .link }.count }
        let text = "See https://example.org and \"quotes\" -- here.\n"
        #expect(links(CMarkTree(text)) == 0)
        #expect(links(CMarkTree(text, options: .init(autolink: true))) == 1)
        func plain(_ tree: CMarkTree) -> String {
            func walk(_ n: CMarkNode) -> String { (n.kind == .text ? n.literal ?? "" : "") + n.children.map(walk).joined() }
            return walk(tree.root)
        }
        #expect(plain(CMarkTree(text)).contains("\"quotes\" --"))
        #expect(plain(CMarkTree(text, options: .init(smartPunctuation: true))).contains("\u{201C}quotes\u{201D} \u{2013}"))
    }
}

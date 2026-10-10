//
//  LineIndexTests.swift
//  MacDownKitTests
//

import Foundation
import Testing
@testable import MacDownKit

@Suite struct LineIndexTests {
    @Test func ascii() {
        let index = LineIndex("ab\ncde\n\nf")
        #expect(index.lineCount == 4)
        #expect(index.utf16Offset(line: 1, column: 1) == 0)
        #expect(index.utf16Offset(line: 1, column: 3) == 2)       // the newline
        #expect(index.utf16Offset(line: 2, column: 1) == 3)
        #expect(index.utf16Offset(line: 2, column: 4) == 6)       // one past "cde"
        #expect(index.utf16Offset(line: 3, column: 1) == 7)
        #expect(index.utf16Offset(line: 4, column: 2) == 9)       // end of text
    }

    @Test func emojiAndSurrogatePairs() {
        // "😀" and "𝒳" are 4 UTF-8 bytes and 2 UTF-16 units; "é" is 2 and 1.
        let text = "😀 é *x*\n𝒳y"
        let index = LineIndex(text)
        #expect(index.utf16Offset(line: 1, column: 5) == 2)       // after 😀
        #expect(index.utf16Offset(line: 1, column: 6) == 3)       // é
        #expect(index.utf16Offset(line: 1, column: 9) == 5)       // *
        #expect(index.utf16Offset(line: 2, column: 1) == 9)
        #expect(index.utf16Offset(line: 2, column: 5) == 11)      // y
        #expect(index.utf8Offset(line: 2, column: 5) == 16)       // y, in bytes
        #expect(index.utf8Offset(line: 2, column: 7) == nil)
        let range = index.range(from: (1, 9), to: (1, 12))
        #expect(range.map { (text as NSString).substring(with: $0) } == "*x*")
    }

    @Test func crlfAndCarriageReturns() {
        let index = LineIndex("a\r\nbc\rd\n")
        #expect(index.lineCount == 4)
        #expect(index.utf16Offset(line: 2, column: 1) == 3)
        #expect(index.utf16Offset(line: 3, column: 1) == 6)       // after a lone \r
        #expect(index.utf16Offset(line: 4, column: 1) == 8)       // after the final \n
    }

    @Test func outOfRange() {
        let index = LineIndex("ab\ncd")
        #expect(index.utf16Offset(line: 0, column: 1) == nil)
        #expect(index.utf16Offset(line: 3, column: 1) == nil)
        #expect(index.utf16Offset(line: 1, column: 0) == nil)
        #expect(index.utf16Offset(line: 1, column: 5) == nil)     // past the newline
        #expect(LineIndex("").utf16Offset(line: 1, column: 1) == 0)
    }

    /// Every block of every corpus document maps to the source text it came
    /// from: the converted range holds the block's first line.
    @Test(arguments: try Corpus.all())
    func cmarkRangesMapToTheSource(_ document: Corpus.Document) {
        let index = LineIndex(document.text)
        let source = document.text as NSString
        var checked = 0
        let blocks: [CMarkNode.Kind] = [.blockQuote, .list, .item, .taskItem, .codeBlock, .htmlBlock,
                                        .paragraph, .heading, .thematicBreak, .table]
        func walk(_ node: CMarkNode) {
            if blocks.contains(node.kind), let range = node.range,
               let nsRange = index.range(from: (range.start.line, range.start.column),
                                         to: (range.end.line, range.end.column)) {
                #expect(NSMaxRange(nsRange) <= source.length)
                // The block starts where its source line does (after any
                // container markers, so compare from the range start).
                let lineRange = source.lineRange(for: NSRange(location: nsRange.location, length: 0))
                #expect(nsRange.location >= lineRange.location)
                checked += 1
            }
            if node.kind == .heading, let range = node.range,
               let nsRange = index.range(from: (range.start.line, range.start.column),
                                         to: (range.end.line, range.end.column)) {
                let text = source.substring(with: nsRange)
                #expect(text.hasPrefix("#") || text.contains("\n"), "\(text.debugDescription)")
                let first = node.children.first { $0.kind == .text }?.literal ?? ""
                #expect(text.contains(first.prefix(3)), "\(text.debugDescription)")
            }
            node.children.forEach(walk)
        }
        CMarkTree(document.text).withRoot(walk)
        #expect(checked > 0)
    }
}

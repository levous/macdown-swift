//
//  ProtectedSource.swift
//  MacDownKit
//
//  Hides math and front matter from the Markdown parser without moving any
//  source position (FR-4, FR-5). Each protected span is replaced by filler of
//  the same UTF-8 length, keeping its line breaks: math by `x`, so it stays a
//  run of text the renderer swaps the original back into; front matter by
//  spaces, so the parser sees only blank lines.
//
//  Math delimiters are MacDown's: `$$…$$`, `\\[…\\]`, `\\(…\\)`, and `$…$`
//  with inline dollars on. A single `\(` is an ordinary Markdown escape. An
//  inline `$` must have a non-space after it, and its closing `$` a non-space
//  before it and no digit after, so amounts like "$5 and $10" aren't math.
//  No span crosses a blank line or enters code or raw HTML.
//

import Foundation

public struct ProtectedSource: Sendable {
    public struct FrontMatter: Sendable {
        /// UTF-8 byte range, from the opening `---` to the end of the closing one.
        public let range: Range<Int>
        public let object: YAMLValue
    }

    public let source: String
    /// `source` with math and front matter replaced by filler.
    public let protected: String
    /// UTF-8 byte ranges of each math span, delimiters included, in order.
    public let math: [Range<Int>]
    public let frontMatter: FrontMatter?

    public init(_ source: String, math: Bool, inlineDollar: Bool) {
        self = Self.protect(source, math: math, inlineDollar: inlineDollar, options: nil).0
    }

    private init(source: String, protected: String, math: [Range<Int>], frontMatter: FrontMatter?) {
        self.source = source
        self.protected = protected
        self.math = math
        self.frontMatter = frontMatter
    }

    /// Protects `source` and parses the result with `options`, reusing the
    /// parse that finds code when no math was found (the text is then
    /// unchanged), so most edits parse once.
    static func parsed(_ source: String, math: Bool, inlineDollar: Bool,
                       options: CMarkTree.Options) -> (ProtectedSource, CMarkTree) {
        let (result, tree) = protect(source, math: math, inlineDollar: inlineDollar,
                                     options: options)
        return (result, tree ?? CMarkTree(result.protected, options: options))
    }

    /// The protection itself. With `options`, also returns the tree of the
    /// protected text when its code-finding parse already is one.
    private static func protect(_ source: String, math: Bool, inlineDollar: Bool,
                                options: CMarkTree.Options?) -> (ProtectedSource, CMarkTree?) {
        var bytes = Array(source.utf8)

        var frontMatter: FrontMatter?
        let (object, utf16Length) = source.frontMatter()
        if let object, utf16Length > 0 {
            let end = String(source.utf16.prefix(utf16Length))!.utf8.count
            frontMatter = FrontMatter(range: 0..<end, object: object)
            fill(&bytes, 0..<end, with: UInt8(ascii: " "))
        }

        var spans: [Range<Int>] = []
        var tree: CMarkTree?
        if math {
            let text = String(decoding: bytes, as: UTF8.self)
            let codeTree = CMarkTree(text, options: options ?? .init())
            spans = findMath(in: bytes, skipping: codeAndHTML(in: codeTree, text: text),
                             inlineDollar: inlineDollar)
            for span in spans { fill(&bytes, span, with: UInt8(ascii: "x")) }
            if spans.isEmpty, options != nil { tree = codeTree }
        }
        let result = ProtectedSource(source: source, protected: String(decoding: bytes, as: UTF8.self),
                                     math: spans, frontMatter: frontMatter)
        return (result, tree)
    }

    private static func fill(_ bytes: inout [UInt8], _ range: Range<Int>, with filler: UInt8) {
        for i in range where bytes[i] != UInt8(ascii: "\n") && bytes[i] != UInt8(ascii: "\r") {
            bytes[i] = filler
        }
    }

    /// UTF-8 ranges of code spans, code blocks and raw HTML, where math
    /// delimiters mean nothing, as the Markdown parser sees them.
    private static func codeAndHTML(in tree: CMarkTree, text: String) -> [Range<Int>] {
        let index = LineIndex(text)
        var ranges: [Range<Int>] = []
        func walk(_ node: CMarkNode) {
            switch node.kind {
            case .code, .codeBlock, .htmlBlock, .htmlInline:
                if let range = node.range,
                   let lower = index.utf8Offset(line: range.start.line, column: range.start.column),
                   let upper = index.utf8Offset(line: range.end.line, column: range.end.column) {
                    ranges.append(lower..<max(lower, upper))
                }
            default:
                node.children.forEach(walk)
            }
        }
        tree.withRoot(walk)
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func findMath(in bytes: [UInt8], skipping skipped: [Range<Int>],
                                 inlineDollar: Bool) -> [Range<Int>] {
        let dollar = UInt8(ascii: "$"), backslash = UInt8(ascii: "\\")
        // Where the span starting at `start` must end: before the next code
        // range or blank line.
        func limit(from start: Int) -> Int {
            var end = skipped.first { $0.lowerBound >= start }?.lowerBound ?? bytes.count
            var i = start
            while i < end {
                if bytes[i] == UInt8(ascii: "\n") {
                    var j = i + 1
                    while j < end, bytes[j] == UInt8(ascii: " ") || bytes[j] == UInt8(ascii: "\t")
                        || bytes[j] == UInt8(ascii: "\r") { j += 1 }
                    if j < end, bytes[j] == UInt8(ascii: "\n") { end = i; break }
                }
                i += 1
            }
            return end
        }
        func isEscaped(_ i: Int) -> Bool {
            var count = 0, j = i - 1
            while j >= 0, bytes[j] == backslash { count += 1; j -= 1 }
            return count % 2 == 1
        }
        func matches(_ delimiter: [UInt8], at i: Int, before end: Int) -> Bool {
            i + delimiter.count <= end && Array(bytes[i..<i + delimiter.count]) == delimiter
        }
        func isSpace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        }

        var spans: [Range<Int>] = []
        var skips = skipped[...]
        var i = 0
        while i < bytes.count {
            if let skip = skips.first, i >= skip.lowerBound {
                i = max(i, skip.upperBound)
                skips = skips.dropFirst()
                continue
            }
            let byte = bytes[i]
            if byte == backslash {
                // `\\(` and `\\[` open math; any other backslash escapes the
                // next character.
                if i + 2 < bytes.count, bytes[i + 1] == backslash,
                   bytes[i + 2] == UInt8(ascii: "(") || bytes[i + 2] == UInt8(ascii: "[") {
                    let close: [UInt8] = [backslash, backslash,
                                          bytes[i + 2] == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "]")]
                    let end = limit(from: i)
                    var j = i + 3
                    while j < end, !matches(close, at: j, before: end) { j += 1 }
                    if j < end {
                        spans.append(i..<j + 3)
                        i = j + 3
                        continue
                    }
                }
                i += 2
                continue
            }
            guard byte == dollar else { i += 1; continue }
            let end = limit(from: i)
            if i + 1 < bytes.count, bytes[i + 1] == dollar {
                var j = i + 2
                while j < end, !(matches([dollar, dollar], at: j, before: end) && !isEscaped(j)) { j += 1 }
                if j < end, j > i + 2 {
                    spans.append(i..<j + 2)
                    i = j + 2
                } else {
                    i += 2
                }
                continue
            }
            if inlineDollar, i + 1 < end, !isSpace(bytes[i + 1]) {
                var j = i + 1
                while j < end {
                    if bytes[j] == dollar, !isEscaped(j), !isSpace(bytes[j - 1]),
                       !(j + 1 < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[j + 1])) {
                        break
                    }
                    j += 1
                }
                if j < end, j > i + 1 {
                    spans.append(i..<j + 1)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return spans
    }
}

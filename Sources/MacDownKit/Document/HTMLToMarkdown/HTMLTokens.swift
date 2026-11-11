//
//  HTMLTokens.swift
//  MacDownKit
//
//  Splits HTML into comments, `style` and `script` elements, tags, the text
//  between them, and a `<` that starts none of those, so every character is
//  in a token.
//

import Foundation

struct HTMLTokens {
    let html: NSString
    private var location = 0
    /// For each terminator, the earliest position a search for it failed
    /// from. A search from there or later would fail too, so it isn't
    /// repeated: without this, every unclosed `<script` or `<!--` in a large
    /// paste would scan to the end again.
    private var missingFrom: [String: Int] = [:]

    private static let rawTextOpener = try! NSRegularExpression(
        pattern: "<(style|script)\\b", options: .caseInsensitive)
    private static let closers = [
        "style": try! NSRegularExpression(pattern: "</style\\s*>", options: .caseInsensitive),
        "script": try! NSRegularExpression(pattern: "</script\\s*>", options: .caseInsensitive),
    ]

    init(_ html: String) {
        self.html = html as NSString
    }

    /// The next token's range, or nil at the end.
    mutating func next() -> NSRange? {
        let start = location
        guard start < html.length else { return nil }
        let end: Int
        if html.character(at: start) == UInt16(UInt8(ascii: "<")) {
            end = markupEnd(at: start)
        } else {
            let lessThan = html.range(of: "<", options: .literal, range: NSRange(start..<html.length))
            end = lessThan.location == NSNotFound ? html.length : lessThan.location
        }
        location = end
        return NSRange(start..<end)
    }

    /// The end of the markup starting with the `<` at `start`.
    private mutating func markupEnd(at start: Int) -> Int {
        let rest = NSRange(start..<html.length)
        if html.range(of: "<!--", options: [.literal, .anchored], range: rest).location != NSNotFound,
           let end = end(of: "-->", from: start + 4) {
            return end
        }
        if let opener = Self.rawTextOpener.firstMatch(in: html as String, options: .anchored, range: rest) {
            let name = html.substring(with: opener.range(at: 1)).lowercased()
            if let end = end(of: name, from: NSMaxRange(opener.range)) { return end }
        }
        return end(of: ">", from: start + 1) ?? start + 1
    }

    /// Where the first `terminator` at or after `position` ends: the text
    /// itself, or for `style` and `script` the element's closing tag.
    private mutating func end(of terminator: String, from position: Int) -> Int? {
        if let missing = missingFrom[terminator], position >= missing { return nil }
        let range = NSRange(position..<html.length)
        let found: NSRange
        if let closer = Self.closers[terminator] {
            found = closer.firstMatch(in: html as String, range: range)?.range ?? NSRange(location: NSNotFound, length: 0)
        } else {
            found = html.range(of: terminator, options: .literal, range: range)
        }
        guard found.location != NSNotFound else {
            missingFrom[terminator] = min(position, missingFrom[terminator] ?? position)
            return nil
        }
        return NSMaxRange(found)
    }
}

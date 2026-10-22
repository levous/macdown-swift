//
//  HTMLDiff.swift
//  MacDownKitTests
//
//  Comparing HTML: normalized so insignificant differences (attribute
//  order, whitespace between tags, entities) don't count, and split into
//  the runs that differ. Used by the paste round trip and the renderer
//  tests.
//

import Foundation
import Testing
@testable import MacDownKit

enum HTMLDiff {
    /// HTML with insignificant differences removed: attributes sorted within
    /// each tag, whitespace between tags dropped, other runs collapsed.
    static func normalize(_ html: String) -> String {
        normalizeTags(decodeEntities(html))
    }

    /// Entities decoded to characters, so `&copy;` (hoedown passes it
    /// through) and `©` (cmark decodes it) compare equal. `&lt; &gt; &amp;
    /// &quot;` stay: decoding them would change the markup.
    static func decodeEntities(_ html: String) -> String {
        guard html.contains("&") else { return html }
        var result = ""
        var rest = Substring(html)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[amp...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let name = String(after[after.index(after: amp)..<semicolon])
                if !["lt", "gt", "amp", "quot"].contains(name),
                   let decoded = Self.decode(name) {
                    result += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after.dropFirst()
        }
        return result + rest
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        let named = ["nbsp": "\u{A0}", "copy": "©", "reg": "®", "trade": "™", "hellip": "…",
                     "mdash": "—", "ndash": "–", "ldquo": "“", "rdquo": "”", "lsquo": "‘",
                     "rsquo": "’", "laquo": "«", "raquo": "»", "middot": "·", "times": "×",
                     "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "sect": "§",
                     "para": "¶", "bull": "•", "apos": "'", "rarr": "→", "larr": "←",
                     "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐",
                     "check": "✓", "minus": "−", "plusmn": "±", "frac12": "½"]
        return named[name]
    }

    static func normalizeTags(_ html: String) -> String {
        var output = String.UnicodeScalarView()
        var text = String.UnicodeScalarView()    // since the last tag
        var hasContent = false
        func flushText() {
            // Whitespace alone between two tags is dropped.
            if hasContent { output.append(contentsOf: text) }
            text.removeAll(keepingCapacity: true)
            hasContent = false
        }
        var scalars = html.unicodeScalars[...]
        while let scalar = scalars.first {
            if scalar == "<", let close = scalars.firstIndex(of: ">") {
                let tag = normalizeTag(String(String.UnicodeScalarView(scalars[...close])))
                if blockClosers.contains(tag), text.last == " " { text.removeLast() }
                flushText()
                output.append(contentsOf: tag.unicodeScalars)
                scalars = scalars[scalars.index(after: close)...]
                continue
            }
            scalars = scalars.dropFirst()
            if scalar.properties.isWhitespace {
                if text.last != " " { text.append(" ") }    // collapse runs
            } else {
                text.append(scalar)
                hasContent = true
            }
        }
        flushText()
        return String(output).trimmingCharacters(in: .whitespaces)
    }

    /// Closing tags of blocks, before which whitespace doesn't show.
    private static let blockClosers: Set<String> = [
        "</p>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
        "</td>", "</th>", "</blockquote>",
    ]

    /// `<name b="2" a='1'>` → `<name a="1" b="2">`. Comments, doctypes and
    /// closing tags are kept as they are.
    private static func normalizeTag(_ tag: String) -> String {
        var chars = Array(tag.unicodeScalars)
        guard chars.count > 2, chars[1].properties.isAlphabetic else { return tag }
        let selfClosing = tag.hasSuffix("/>")
        chars.removeLast(selfClosing ? 2 : 1)
        var index = 1
        func read(while condition: (Unicode.Scalar) -> Bool) -> String {
            var result = String.UnicodeScalarView()
            while index < chars.count, condition(chars[index]) {
                result.append(chars[index]); index += 1
            }
            return String(result)
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
        let name = read { !isSpace($0) && $0 != "/" }
        var attributes: [String] = []
        while true {
            _ = read { isSpace($0) || $0 == "/" }
            guard index < chars.count else { break }
            let key = read { !isSpace($0) && $0 != "=" && $0 != "/" }
            _ = read(while: isSpace)
            guard index < chars.count, chars[index] == "=" else {
                attributes.append(key); continue
            }
            index += 1
            _ = read(while: isSpace)
            var value: String
            if index < chars.count, chars[index] == "\"" || chars[index] == "'" {
                let quote = chars[index]; index += 1
                value = read { $0 != quote }
                index += 1
            } else {
                value = read { !isSpace($0) }
            }
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            attributes.append("\(key)=\"\(value)\"")
        }
        return "<" + ([name] + attributes.sorted()).joined(separator: " ")
            + (selfClosing ? " />" : ">")
    }

    /// A run of differing tokens: what the left side has there, and what
    /// the right one has.
    struct Hunk: Sendable, Equatable {
        let left: String
        let right: String
    }

    /// Tags and words (with their spacing) of normalized HTML.
    static func tokens(_ html: String) -> [Substring] {
        html.matches(of: /<[^>]*>|[^<\s]+|\s/).map(\.output)
    }

    /// The differing token runs between two normalized HTML strings.
    static func hunks(_ left: String, _ right: String) -> [Hunk] {
        let a = tokens(left), b = tokens(right)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Tokens that aren't removed (left) or inserted (right) match in
        // order, so walk both and collect each run of changes.
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && !removed.contains(i) && j < b.count && !inserted.contains(j) {
                i += 1; j += 1; continue
            }
            var l = "", r = ""
            while i < a.count && removed.contains(i) { l += a[i]; i += 1 }
            while j < b.count && inserted.contains(j) { r += b[j]; j += 1 }
            hunks.append(Hunk(left: l, right: r))
        }
        return hunks
    }
}

@Suite struct HTMLDiffTests {
    @Test func normalizerIgnoresAttributeOrderAndWhitespace() {
        let a = #"<p>Hi</p>   <img src="a.png" alt='x'/>"# + "\n<div class=\"c\" id=\"d\">\n  text\n</div>"
        let b = #"<p>Hi</p><img alt="x" src="a.png" />"# + #"<div id="d" class="c"> text </div>"#
        #expect(HTMLDiff.normalize(a) == HTMLDiff.normalize(b))
        #expect(HTMLDiff.normalize("<input checked disabled type=checkbox>")
                == HTMLDiff.normalize("<input type=checkbox disabled checked>"))
        // Real differences survive.
        #expect(HTMLDiff.normalize("<p>Hi</p>") != HTMLDiff.normalize("<p>Hi!</p>"))
        #expect(HTMLDiff.normalize(#"<a href="x">"#) != HTMLDiff.normalize(#"<a href="y">"#))
        #expect(HTMLDiff.normalize("<em>x</em>") != HTMLDiff.normalize("<i>x</i>"))
    }

    @Test func hunksAreTheDifferingRuns() {
        let hunks = HTMLDiff.hunks("<p>one two three</p><p>four</p>",
                                   "<p>one 2 three</p><p>four five</p>")
        #expect(hunks == [HTMLDiff.Hunk(left: "two", right: "2"),
                          HTMLDiff.Hunk(left: "", right: " five")])
    }

    @Test func entitiesDecodeForComparison() {
        #expect(HTMLDiff.normalize("<p>&copy; &#169; &#xA9; ©</p>") == "<p>© © © ©</p>")
        #expect(HTMLDiff.normalize("<p>&lt;b&gt; &amp; &quot;</p>") == "<p>&lt;b&gt; &amp; &quot;</p>")
    }
}

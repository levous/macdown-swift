//
//  String+Lookup.swift
//  MacDown
//
//  Ported from NSString+Lookup.m. Locations are UTF-16 offsets, matching
//  NSString/NSTextView semantics.
//

import Foundation
import Yams

extension NSString {
    /// Location of the newline before `location`, or -1 if on the first line.
    public func locationOfFirstNewline(before location: Int) -> Int {
        let location = min(location, length)
        var start = 0
        getLineStart(&start, end: nil, contentsEnd: nil,
                     for: NSRange(location: location, length: 0))
        return start - 1
    }

    public func locationOfFirstNewline(after location: Int) -> Int {
        let location = min(location + 1, length)
        var end = 0
        getLineStart(nil, end: nil, contentsEnd: &end,
                     for: NSRange(location: location, length: 0))
        return end
    }

    public func locationOfFirstNonWhitespaceCharacterInLine(before loc: Int) -> Int {
        var p = locationOfFirstNewline(before: loc) + 1
        let loc = min(loc, length)
        while p < loc && MPCharacters.isWhitespace(character(at: p)) {
            p += 1
        }
        return p
    }

    /// Text of the highest ranked ATX heading in the document.
    public var titleString: String? {
        var pattern = "\\s+(\\S.*)$"
        for _ in 0..<6 {
            pattern = "#" + pattern
            guard let regex = try? NSRegularExpression(
                pattern: "^" + pattern, options: .anchorsMatchLines)
            else { continue }
            if let result = regex.firstMatch(
                in: self as String, range: NSRange(location: 0, length: length)) {
                return substring(with: result.range(at: 1))
            }
        }
        return nil
    }
}

extension String {
    public var ns: NSString { self as NSString }

    public func hasExtension(_ ext: String) -> Bool {
        (self as NSString).pathExtension == ext
    }

    public var titleString: String? { ns.titleString }

    /// Parses Jekyll-style front matter at the start of the string.
    ///
    /// - Returns: The parsed YAML object (if any) and the UTF-16 length of
    ///   the front matter block, which should be skipped when rendering.
    public func frontMatter() -> (object: YAMLValue?, offset: Int) {
        let pattern = "^-{3}[\r\n]+(.*?[\r\n]+)((?:-{3})|(?:\\.{3}))"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: .dotMatchesLineSeparators),
              let result = regex.firstMatch(
                in: self, range: NSRange(location: 0, length: ns.length))
        else { return (nil, 0) }

        let yaml = ns.substring(with: result.range(at: 1))
        guard let node = try? Yams.compose(yaml: yaml) else { return (nil, 0) }
        return (YAMLValue(node: node), result.range(at: 0).length)
    }
}

/// An ordered representation of a YAML document, with all scalars kept as
/// strings (equivalent to the original `kYAMLReadOptionStringScalars`).
public indirect enum YAMLValue: Equatable, Sendable {
    case null
    case string(String)
    case sequence([YAMLValue])
    case mapping([(key: YAMLValue, value: YAMLValue)])

    init(node: Node) {
        switch node {
        case .scalar(let scalar):
            if scalar.tag == Tag(.null) || (scalar.style == .plain
                && ["", "~", "null", "Null", "NULL"].contains(scalar.string)) {
                self = .null
            } else {
                self = .string(scalar.string)
            }
        case .sequence(let seq):
            self = .sequence(seq.map(YAMLValue.init(node:)))
        case .mapping(let map):
            self = .mapping(map.map {
                (key: YAMLValue(node: $0.key), value: YAMLValue(node: $0.value))
            })
        case .alias:
            self = .null
        }
    }

    public subscript(key: String) -> YAMLValue? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first { $0.key == .string(key) }?.value
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .null: return nil
        default: return description
        }
    }

    public static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.string(a), .string(b)): return a == b
        case let (.sequence(a), .sequence(b)): return a == b
        case let (.mapping(a), .mapping(b)):
            return a.count == b.count && zip(a, b).allSatisfy {
                $0.key == $1.key && $0.value == $1.value
            }
        default: return false
        }
    }
}

extension YAMLValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "<null>"
        case .string(let s): return s
        case .sequence(let items):
            return "(" + items.map(\.description).joined(separator: ", ") + ")"
        case .mapping(let pairs):
            return "{" + pairs.map { "\($0.key) = \($0.value)" }
                .joined(separator: "; ") + "}"
        }
    }
}

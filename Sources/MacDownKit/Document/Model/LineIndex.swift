//
//  LineIndex.swift
//  MacDownKit
//
//  Converts swift-markdown source positions (1-based line, and 1-based column
//  in UTF-8 bytes) to the UTF-16 offsets NSString and NSTextView use
//  (TR-3). Lines end at "\n", "\r\n" or a lone "\r", as in cmark.
//

import Foundation

public struct LineIndex: Sendable {
    private let utf8: [UInt8]
    /// For each line, the UTF-8 and UTF-16 offsets of its first character.
    private let lineStarts: [(utf8: Int, utf16: Int)]

    public init(_ source: String) {
        utf8 = Array(source.utf8)
        var starts = [(utf8: 0, utf16: 0)]
        var utf16 = 0
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            utf16 += Self.utf16Units(lead: byte)
            i += 1
            if byte == UInt8(ascii: "\n")
                || (byte == UInt8(ascii: "\r") && (i == utf8.count || utf8[i] != UInt8(ascii: "\n"))) {
                starts.append((i, utf16))
            }
        }
        lineStarts = starts
    }

    public var lineCount: Int { lineStarts.count }

    /// The UTF-8 offset of a 1-based line and UTF-8 column, with the same
    /// bounds as `utf16Offset(line:column:)`.
    public func utf8Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
        let lineEnd = line < lineStarts.count ? lineStarts[line].utf8 : utf8.count
        let byte = lineStarts[line - 1].utf8 + column - 1
        return byte <= lineEnd ? byte : nil
    }

    /// The UTF-16 offset of a 1-based line and UTF-8 column. The column may
    /// be one past the line's last byte (exclusive range ends). Nil when the
    /// position isn't in the text.
    public func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
        let start = lineStarts[line - 1]
        let lineEnd = line < lineStarts.count ? lineStarts[line].utf8 : utf8.count
        let byte = start.utf8 + column - 1
        guard byte <= lineEnd else { return nil }
        var utf16 = start.utf16
        for i in start.utf8..<byte {
            utf16 += Self.utf16Units(lead: utf8[i])
        }
        return utf16
    }

    /// The 1-based line a UTF-8 offset is on.
    public func lineNumber(utf8 offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid].utf8 <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// The UTF-16 offset of a UTF-8 offset into the text.
    public func utf16Offset(utf8 offset: Int) -> Int? {
        guard offset >= 0, offset <= utf8.count else { return nil }
        // The last line starting at or before the offset.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid].utf8 <= offset { low = mid } else { high = mid - 1 }
        }
        return utf16Offset(line: low + 1, column: offset - lineStarts[low].utf8 + 1)
    }

    /// The UTF-16 range between two (line, column) positions, end exclusive.
    public func range(from start: (line: Int, column: Int),
                      to end: (line: Int, column: Int)) -> NSRange? {
        guard let lower = utf16Offset(line: start.line, column: start.column),
              let upper = utf16Offset(line: end.line, column: end.column),
              upper >= lower
        else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// UTF-16 units contributed by a UTF-8 byte: continuation bytes add
    /// none, the lead byte of a 4-byte sequence (outside the BMP) two.
    private static func utf16Units(lead byte: UInt8) -> Int {
        switch byte {
        case 0x80..<0xC0: 0
        case 0xF0...: 2
        default: 1
        }
    }
}

//
//  NSTextView+Autocomplete.swift
//  MacDown
//
//  Ported from NSTextView+Autocomplete.m. All locations are UTF-16 offsets.
//

import AppKit

private let leftSingleQuotation: unichar = 0x2018
private let rightSingleQuotation: unichar = 0x2019
private let leftDoubleQuotation: unichar = 0x201C
private let rightDoubleQuotation: unichar = 0x201D

private let matchingCharactersMap: [(unichar, unichar)] = [
    (0x28, 0x29),           // ( )
    (0x5B, 0x5D),           // [ ]
    (0x7B, 0x7D),           // { }
    (0x3C, 0x3E),           // < >
    (0x27, 0x27),           // ' '
    (0x22, 0x22),           // " "
    (0xFF08, 0xFF09),       // full-width parentheses
    (0x300C, 0x300D),       // corner brackets
    (0x300E, 0x300F),       // white corner brackets
    (leftSingleQuotation, rightSingleQuotation),
    (leftDoubleQuotation, rightDoubleQuotation),
    (0x2039, 0x203A),       // Latin single guillemet
    (0x00AB, 0x00BB),       // Latin double guillemet
    (0x3008, 0x3009),       // East Asian single guillemet
    (0x300A, 0x300B),       // East Asian double guillemet
]

private let strikethroughCharacter: unichar = 0x7E    // ~
private let markupCharacters: [unichar] = [0x2A, 0x5F, 0x60, 0x3D]  // * _ ` =

private let listLineHeadPattern =
    "^(\\s*)((?:(?:\\*|\\+|-|)\\s+)?)((?:\\d+\\.\\s+)?)(\\S)?"
private let blockquoteLinePattern = "^((?:\\> ?)+).*$"

private let boundaryCharacters: CharacterSet =
    CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

private func isBoundary(_ c: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    return boundaryCharacters.contains(scalar)
}

private func chars(_ chars: unichar...) -> String {
    String(utf16CodeUnits: chars, count: chars.count)
}

extension NSTextView {
    private var nsString: NSString { string as NSString }

    func substring(in range: NSRange, isSurroundedByPrefix prefix: String,
                   suffix: String) -> Bool {
        let content = nsString
        let location = range.location
        let length = range.length
        let p = prefix as NSString, s = suffix as NSString
        if content.length < location + length + s.length { return false }
        if location < p.length { return false }

        guard content.substring(from: location + length).hasPrefix(suffix),
              content.substring(to: location).hasSuffix(prefix)
        else { return false }

        // Emphasis (*) requires special treatment because we need to eliminate
        // strong (**) but not strong-emphasis (***).
        if prefix != "*" || suffix != "*" { return true }
        if substring(in: range, isSurroundedByPrefix: "***", suffix: "***") { return true }
        if substring(in: range, isSurroundedByPrefix: "**", suffix: "**") { return false }
        return true
    }

    public func insertSpacesForTab() {
        var spaces = "    "
        let current = selectedRange().location
        let p = nsString.locationOfFirstNewline(before: current)
        // Calculate how deep we need to go.
        let offset = (current - p - 1) % 4
        if offset > 0 {
            spaces = String(spaces.dropFirst(offset))
        }
        insertText(spaces, replacementRange: selectedRange())
    }

    public func completeMatchingCharacters(forTextIn range: NSRange,
                                           with str: String,
                                           strikethroughEnabled: Bool) -> Bool {
        let length = (str as NSString).length
        if range.length == 0 && length == 1 {
            // Character insert without selection.
            return completeMatchingCharacter(for: str, at: range.location)
        } else if range.length > 0 && length == 1 {
            // Character insert with selection (i.e. select and replace).
            let character = (str as NSString).character(at: 0)
            return wrapMatchingCharacters(of: character, aroundTextIn: range,
                                          strikethroughEnabled: strikethroughEnabled)
        }
        return false
    }

    func completeMatchingCharacter(for str: String, at location: Int) -> Bool {
        let content = nsString
        let contentLength = content.length
        let marked = hasMarkedText()
        let c = (str as NSString).character(at: 0)
        var n: unichar = 0x20
        var p: unichar = 0x20
        if location < contentLength { n = content.character(at: location) }
        if location > 0 && location <= contentLength {
            p = content.character(at: location - 1)
        }

        for (open, close) in matchingCharactersMap {
            // Ignore IM input of ASCII characters.
            if marked && open < 0x100 { continue }

            if isBoundary(n) && c == open && (isBoundary(p) || open != close) {
                // First part of matching characters.
                var range = NSRange(location: location, length: 0)
                var completion = chars(open, close)
                // Mimic macOS's quote substitution if it's on.
                if isAutomaticQuoteSubstitutionEnabled {
                    if open == 0x22 {
                        completion = chars(leftDoubleQuotation)
                    } else if open == 0x27 {
                        completion = chars(leftSingleQuotation)
                    }
                }
                insertText(completion, replacementRange: range)
                range.location += (str as NSString).length
                setSelectedRange(range)
                return true
            } else if c == close && n == close {
                // Second part of matching characters (shift without inserting).
                setSelectedRange(NSRange(location: location + 1, length: 0))
                return true
            }
        }
        return false
    }

    func wrapText(in range: NSRange, prefix: unichar, suffix: unichar) {
        let text = nsString.substring(with: range)
        insertText(chars(prefix) + text + chars(suffix), replacementRange: range)
        var range = range
        range.location += 1
        setSelectedRange(range)
    }

    func wrapMatchingCharacters(of character: unichar, aroundTextIn range: NSRange,
                                strikethroughEnabled: Bool) -> Bool {
        for (open, close) in matchingCharactersMap where character == open {
            wrapText(in: range, prefix: open, suffix: close)
            return true
        }
        if markupCharacters.contains(character) {
            wrapText(in: range, prefix: character, suffix: character)
            return true
        }
        if strikethroughEnabled && character == strikethroughCharacter {
            wrapText(in: range, prefix: character, suffix: character)
            return true
        }
        return false
    }

    public func deleteMatchingCharacters(around location: Int) -> Bool {
        let content = nsString
        if location == 0 || location >= content.length { return false }
        let f = content.character(at: location - 1)
        let b = content.character(at: location)
        for (open, close) in matchingCharactersMap where f == open && b == close {
            let range = NSRange(location: location - 1, length: 2)
            if shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
            }
            return true
        }
        return false
    }

    public func unindentForSpaces(before location: Int) -> Bool {
        let content = nsString
        var whitespaceCount = 0
        while location - whitespaceCount > 0
                && content.character(at: location - whitespaceCount - 1) == 0x20 {
            whitespaceCount += 1
            if whitespaceCount >= 4 { break }
        }
        if whitespaceCount < 2 { return false }

        let lineStart = content.locationOfFirstNewline(before: location) + 1
        if location <= lineStart { return false }

        var offset = (location - lineStart) % 4
        if offset == 0 { offset = 4 }
        if whitespaceCount < offset { offset = whitespaceCount }

        let range = NSRange(location: location - offset, length: offset)
        if shouldChangeText(in: range, replacementString: "") {
            replaceCharacters(in: range, with: "")
            didChangeText()
        }
        return true
    }

    /// Toggles inline markup around the selection.
    ///
    /// - Returns: Whether the markup is now on.
    @discardableResult
    public func toggleForMarkup(prefix: String, suffix: String) -> Bool {
        var range = selectedRange()
        let selection = nsString.substring(with: range)
        let poff = (prefix as NSString).length
        let isOn: Bool
        if substring(in: range, isSurroundedByPrefix: prefix, suffix: suffix) {
            // Selection is already marked-up. Clear markup, maintain selection.
            let sub = NSRange(location: range.location - poff,
                              length: (selection as NSString).length + poff
                                  + (suffix as NSString).length)
            insertText(selection, replacementRange: sub)
            range.location = sub.location
            isOn = false
        } else {
            // Selection is normal. Mark it up and maintain selection.
            insertText(prefix + selection + suffix, replacementRange: range)
            range.location += poff
            isOn = true
        }
        setSelectedRange(range)
        return isOn
    }

    public func toggleBlock(pattern: String, prefix: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let content = nsString
        var selectedRange = self.selectedRange()
        let lineRange = content.lineRange(for: selectedRange)

        var toProcess = content.substring(with: lineRange)
        var hasTrailingNewline = false
        if toProcess.hasSuffix("\n") {
            toProcess.removeLast()
            hasTrailingNewline = true
        }
        let lines = toProcess.components(separatedBy: "\n")

        var isMarked = true
        for line in lines {
            let match = regex.rangeOfFirstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length))
            if match.location == NSNotFound {
                isMarked = false
                break
            }
        }

        let prefixLength = (prefix as NSString).length
        var totalShift = 0
        let modLines = lines.map { line -> String in
            if !line.isEmpty { totalShift += prefixLength }
            if !isMarked { return prefix + line }
            return (line as NSString).substring(from: prefixLength)
        }

        var processed = modLines.joined(separator: "\n")
        if hasTrailingNewline { processed += "\n" }
        insertText(processed, replacementRange: lineRange)

        if !isMarked {
            selectedRange.location += prefixLength
            if selectedRange.length + totalShift >= prefixLength {
                selectedRange.length += totalShift - prefixLength
            } else {
                selectedRange.length = 0
            }
        } else {
            if prefixLength <= selectedRange.location {
                selectedRange.location -= prefixLength
            } else {
                selectedRange.location = 0
            }
            if totalShift - prefixLength <= selectedRange.length {
                selectedRange.length -= totalShift - prefixLength
            } else {
                selectedRange.length = 0
            }
            if selectedRange.location < lineRange.location {
                selectedRange.length -= lineRange.location - selectedRange.location
                selectedRange.location = lineRange.location
            }
        }
        setSelectedRange(selectedRange)
    }

    public func indentSelectedLines(padding: String) {
        let content = nsString
        var selectedRange = self.selectedRange()
        let lineRange = content.lineRange(for: selectedRange)

        let lines = content.substring(with: lineRange).components(separatedBy: "\n")
        let paddingLength = (padding as NSString).length
        var totalShift = 0
        var modLines = lines.map { line -> String in
            if !line.isEmpty { totalShift += paddingLength }
            return padding + line
        }
        if modLines.last == padding {
            modLines[modLines.count - 1] = ""
        }
        insertText(modLines.joined(separator: "\n"), replacementRange: lineRange)

        selectedRange.location += paddingLength
        selectedRange.length += totalShift > paddingLength ? totalShift - paddingLength : 0
        setSelectedRange(selectedRange)
    }

    public func unindentSelectedLines() {
        let content = nsString
        var selectedRange = self.selectedRange()
        let lineRange = content.lineRange(for: selectedRange)

        let lines = content.substring(with: lineRange).components(separatedBy: "\n")
        var firstShift = 0      // Indentation of the first line.
        var totalShift = 0      // Indents removed in total.
        var modLines: [String] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            let lineLength = ns.length
            var shift = 0
            while shift < 4 {
                if shift >= lineLength { break }
                let c = ns.character(at: shift)
                if c == 0x09 { shift += 1 }     // Tab.
                if c != 0x20 { break }
                shift += 1
            }
            if index == 0 { firstShift += shift }
            totalShift += shift
            if shift > 0 && shift < lineLength {
                modLines.append(ns.substring(from: shift))
            } else {
                modLines.append(line)
            }
        }
        insertText(modLines.joined(separator: "\n"), replacementRange: lineRange)

        selectedRange.location -= firstShift
        selectedRange.length -= totalShift - firstShift
        setSelectedRange(selectedRange)
    }

    public func completeNextListItem(autoIncrement: Bool) -> Bool {
        let selectedRange = self.selectedRange()
        var location = selectedRange.location
        let content = nsString
        if selectedRange.length > 0 || content.length == 0 { return false }

        let start = content.locationOfFirstNewline(before: location) + 1
        let end = location
        let nonwhitespace = content.locationOfFirstNonWhitespaceCharacterInLine(before: location)

        // No non-whitespace character at this line.
        if nonwhitespace == location { return false }

        let range = NSRange(location: start, length: end - start)
        let line = content.substring(with: range)
        let lineNS = line as NSString

        guard let regex = try? NSRegularExpression(pattern: listLineHeadPattern,
                                                   options: .anchorsMatchLines),
              let result = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: lineNS.length))
        else { return false }

        var t: String?
        let isUl = result.range(at: 2).length != 0
        let isOl = result.range(at: 3).length != 0
        let previousLineEmpty = result.range(at: 4).length == 0
        if previousLineEmpty {
            var replaceRange = NSRange(location: NSNotFound, length: 0)
            if isUl {
                replaceRange = result.range(at: 2)
            } else if isOl {
                replaceRange = result.range(at: 3)
            }
            if replaceRange.length > 0 {
                if shouldChangeText(in: range, replacementString: "") {
                    replaceCharacters(in: range, with: "")
                    didChangeText()
                }
            }
            t = ""
        } else if isUl {
            var r = result.range(at: 2)
            r.length -= 1       // Exclude trailing whitespace.
            t = lineNS.substring(with: r)
        } else if isOl {
            var r = result.range(at: 3)
            r.length -= 1       // Exclude trailing space.
            var i = Int(lineNS.substring(with: r)
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))) ?? 0
            if autoIncrement { i += 1 }
            t = "\(i)."
        }
        guard let t else { return false }

        insertNewline(self)
        location += 1   // Shift for inserted newline.

        let indent = lineNS.substring(with: result.range(at: 1))
        let after = nsString
        let contentLength = after.length
        let tLength = (t as NSString).length

        // Has matching list item. Only insert indent.
        if contentLength > location + tLength,
           after.substring(with: NSRange(location: location, length: tLength)) == t {
            insertText(indent, replacementRange: self.selectedRange())
            return true
        }

        var it = indent + t
        let itLength = (it as NSString).length
        // Has indent and matching list item. Accept it.
        if contentLength > location + itLength,
           after.substring(with: NSRange(location: location, length: itLength)) == it {
            return true
        }

        // Insert completion for normal cases.
        if !t.isEmpty { it += " " }
        insertText(it, replacementRange: self.selectedRange())
        return true
    }

    public func completeNextBlockquoteLine() -> Bool {
        let selectedRange = self.selectedRange()
        let content = nsString
        let contentLength = content.length
        if selectedRange.length > 0 || contentLength == 0 { return false }

        let lineRange = content.lineRange(for: selectedRange)
        let line = content.substring(with: lineRange)
        guard let regex = try? NSRegularExpression(pattern: blockquoteLinePattern,
                                                   options: .anchorsMatchLines),
              let result = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: lineRange.length))
        else { return false }

        insertNewline(self)

        let markersRange = result.range(at: 1)
        let markers = (line as NSString).substring(with: markersRange)
        let nextLineStart = selectedRange.location + 1

        // Has identical markers. Accept this.
        let after = nsString
        if after.length > nextLineStart + markersRange.length {
            let next = after.substring(with: NSRange(location: nextLineStart,
                                                     length: markersRange.length))
            if next == markers { return true }
        }
        insertText(markers, replacementRange: self.selectedRange())
        return true
    }

    public func completeNextIndentedLine() -> Bool {
        let selectedRange = self.selectedRange()
        if selectedRange.length > 0 { return false }
        let content = nsString
        let start = content.lineRange(for: selectedRange).location
        let end = content.locationOfFirstNonWhitespaceCharacterInLine(
            before: selectedRange.location)
        if end <= start { return false }

        let indent = content.substring(with: NSRange(location: start, length: end - start))
        insertNewline(self)
        insertText(indent, replacementRange: self.selectedRange())
        return true
    }

    public func makeHeaderForSelectedLines(level: Int) {
        precondition(level <= 6, "Should be 1-6, or 0 (convert to paragraph).")
        let content = nsString
        var selectedRange = self.selectedRange()
        let lineRange = content.lineRange(for: selectedRange)

        var header = String("###### ".dropFirst(6 - level))
        if level == 0 { header = "" }
        let headerLength = (header as NSString).length
        guard let regex = try? NSRegularExpression(
            pattern: "^(#+ )*.*?$", options: .dotMatchesLineSeparators)
        else { return }

        let lines = content.substring(with: lineRange).components(separatedBy: "\n")
        var processed: [String] = []
        var firstShift = 0
        var totalShift = 0
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            // Don't process empty/whitespace-only lines unless it's the only line.
            if lines.count > 1 {
                let sentinel = ns.locationOfFirstNonWhitespaceCharacterInLine(before: ns.length)
                if sentinel == ns.length {
                    processed.append(line)
                    continue
                }
            }
            let result = regex.firstMatch(in: line, range: NSRange(location: 0,
                                                                  length: ns.length))
            var lineContent = line
            var headerRange = NSRange(location: 0, length: 0)
            if let result, result.numberOfRanges > 1 {
                headerRange = result.range(at: 1)
            }
            if headerRange.location != NSNotFound {
                lineContent = ns.substring(from: headerRange.location + headerRange.length)
            } else {
                headerRange = NSRange(location: 0, length: 0)
            }
            processed.append(header + lineContent)

            let shift = headerLength - headerRange.length
            if index == 0 { firstShift += shift }
            totalShift += shift
        }
        insertText(processed.joined(separator: "\n"), replacementRange: lineRange)

        selectedRange.location = max(0, selectedRange.location + firstShift)
        selectedRange.length = max(0, selectedRange.length + totalShift - firstShift)
        setSelectedRange(selectedRange)
    }
}

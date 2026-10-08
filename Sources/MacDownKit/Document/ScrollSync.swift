//
//  ScrollSync.swift
//  MacDown
//
//  Scroll synchronization between the editor and the preview.
//
//  Both panes report "anchors": headers and stand-alone images, in document
//  order. Anchors are paired by index, so both sides must apply the same
//  rules (see `ScrollAnchors.scan` and `PreviewController.fetchMetrics`).
//  Pairs give a piecewise linear map between editor and preview content
//  positions. Each pane is aligned at a focus line, which sits at the middle
//  of the visible area, except within the first and last screen of the
//  document where it tapers to the top and bottom edges, so both panes reach
//  their top and bottom together.
//

import Foundation

public enum ScrollAnchorKind: Sendable, Equatable {
    case header
    case image
}

public struct ScrollAnchor: Sendable, Equatable {
    public var kind: ScrollAnchorKind
    /// Vertical center of the anchor, in content coordinates.
    public var position: CGFloat

    public init(_ kind: ScrollAnchorKind, _ position: CGFloat) {
        self.kind = kind
        self.position = position
    }
}

/// Finds anchors in Markdown source, mirroring how hoedown renders them.
///
/// Headers are ATX headers (`#` in the first column) and setext headers
/// (`===` or `---` under a paragraph line). Images count only when they make
/// up a whole top-level paragraph, one anchor per image; the preview applies
/// the same rule to `<p>` elements that contain nothing but images. Fenced
/// code blocks, HTML comment blocks and front matter are skipped.
public enum ScrollAnchors {
    public struct SourceAnchor: Sendable, Equatable {
        public var kind: ScrollAnchorKind
        /// Character range (UTF-16) whose center is the anchor.
        public var range: NSRange
    }

    private static let fenceRegex = try! NSRegularExpression(
        pattern: "^ {0,3}(`{3,}|~{3,})")
    private static let setextRegex = try! NSRegularExpression(
        pattern: "^(=+|-+) *$")
    private static let hruleRegex = try! NSRegularExpression(
        pattern: "^ {0,3}([-*_])( *\\1){2,} *$")
    private static let blockStartRegex = try! NSRegularExpression(
        pattern: "^( {0,3}([-*+]|\\d+\\.)[ \\t]| {0,3}>| {4}|\\t| {0,3}\\|)")
    private static let imageRegex = try! NSRegularExpression(
        pattern: "!\\[[^\\]]*\\](?:\\([^)]*\\)|\\[[^\\]]*\\])")
    private static let imageLineRegex = try! NSRegularExpression(
        pattern: "^ {0,3}(?:!\\[[^\\]]*\\](?:\\([^)]*\\)|\\[[^\\]]*\\])[ \\t]*)+$")

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
            != nil
    }

    public static func scan(_ markdown: String, skipsFrontMatter: Bool) -> [SourceAnchor] {
        var anchors: [SourceAnchor] = []
        var location = 0
        if skipsFrontMatter {
            location = markdown.frontMatter().offset
        }
        let text = (markdown as NSString).substring(from: location)

        var fence: (character: Character, width: Int)?
        var inComment = false
        // Lines of the current paragraph, as (location, line).
        var paragraph: [(Int, String)] = []
        // Whether the previous line can be the text of a setext header.
        var previousIsParagraphText = false

        func flushParagraph() {
            defer { paragraph.removeAll() }
            guard !paragraph.isEmpty,
                  paragraph.allSatisfy({ matches(imageLineRegex, $0.1) })
            else { return }
            for (lineLocation, line) in paragraph {
                let ns = line as NSString
                for match in imageRegex.matches(
                    in: line, range: NSRange(location: 0, length: ns.length)) {
                    anchors.append(SourceAnchor(
                        kind: .image,
                        range: NSRange(location: lineLocation + match.range.location,
                                       length: match.range.length)))
                }
            }
        }

        for line in text.components(separatedBy: "\n") {
            let lineLocation = location
            let length = (line as NSString).length
            location += length + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                let marker = trimmed.prefix(while: { $0 == open.character })
                if marker.count >= open.width && marker.count == trimmed.count {
                    fence = nil
                }
                continue
            }
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if let match = fenceRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: length)) {
                flushParagraph()
                previousIsParagraphText = false
                let marker = (line as NSString).substring(with: match.range(at: 1))
                fence = (marker.first!, marker.count)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                previousIsParagraphText = false
                continue
            }
            if paragraph.isEmpty && line.hasPrefix("<!--") {
                inComment = !line.contains("-->")
                previousIsParagraphText = false
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                anchors.append(SourceAnchor(
                    kind: .header, range: NSRange(location: lineLocation, length: length)))
                previousIsParagraphText = false
                continue
            }
            if previousIsParagraphText && matches(setextRegex, line),
               let last = paragraph.last {
                // The paragraph's last line becomes the header text.
                paragraph.removeLast()
                flushParagraph()
                anchors.append(SourceAnchor(
                    kind: .header,
                    range: NSRange(location: last.0, length: location - 1 - last.0)))
                previousIsParagraphText = false
                continue
            }
            if matches(hruleRegex, line) {
                flushParagraph()
                previousIsParagraphText = false
                continue
            }
            if paragraph.isEmpty && matches(blockStartRegex, line) {
                // Lists, quotes, code and tables: not top-level paragraphs.
                // Following lines belong to the same block until a blank line.
                paragraph.append((lineLocation, "\u{0}"))
                previousIsParagraphText = false
                continue
            }
            paragraph.append((lineLocation, line))
            previousIsParagraphText = paragraph.first?.1 != "\u{0}"
        }
        flushParagraph()
        return anchors
    }
}

/// Vertical geometry of one scrolling pane.
public struct ScrollGeometry: Sendable, Equatable {
    public var contentHeight: CGFloat
    public var visibleHeight: CGFloat

    public init(contentHeight: CGFloat, visibleHeight: CGFloat) {
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
    }

    public var maxOffset: CGFloat { max(0, contentHeight - visibleHeight) }

    /// Where the focus line sits in the visible area (0 = top, 1 = bottom)
    /// at a scroll offset: the middle, tapering to the top edge within the
    /// first screen and to the bottom edge within the last.
    func focusRatio(at offset: CGFloat) -> CGFloat {
        let ramp = min(visibleHeight, maxOffset / 2)
        guard ramp > 0 else { return 0 }
        let fromTop = min(1, max(0, offset / ramp))
        let fromBottom = min(1, max(0, (maxOffset - offset) / ramp))
        return 0.5 * fromTop + 0.5 * (1 - fromBottom)
    }

    /// Content position of the focus line at a scroll offset.
    public func focus(at offset: CGFloat) -> CGFloat {
        let offset = min(max(0, offset), maxOffset)
        return offset + focusRatio(at: offset) * visibleHeight
    }

    /// Scroll offset that puts the focus line at a content position. This
    /// inverts `focus(at:)`, which is strictly increasing.
    public func offset(forFocus position: CGFloat) -> CGFloat {
        var low: CGFloat = 0
        var high = maxOffset
        guard high > 0 else { return 0 }
        if position <= focus(at: low) { return low }
        if position >= focus(at: high) { return high }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if focus(at: mid) < position { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

/// Piecewise linear map between editor and preview content positions.
public struct ScrollMap: Sendable, Equatable {
    /// (editor, preview) positions, strictly increasing in both.
    public private(set) var pairs: [(editor: CGFloat, preview: CGFloat)]

    public static func == (lhs: ScrollMap, rhs: ScrollMap) -> Bool {
        lhs.pairs.elementsEqual(rhs.pairs) { $0 == $1 }
    }

    /// - Parameters:
    ///   - editorEnd: Editor position of the end of the text.
    ///   - previewEnd: Preview content height.
    public init(editor: [ScrollAnchor], preview: [ScrollAnchor],
                editorEnd: CGFloat, previewEnd: CGFloat) {
        var editor = editor
        var preview = preview
        if editor.map(\.kind) != preview.map(\.kind) {
            // Something the rules didn't anticipate; headers are the most
            // reliable, so try them alone before giving up on anchors.
            editor = editor.filter { $0.kind == .header }
            preview = preview.filter { $0.kind == .header }
            if editor.count != preview.count {
                editor = []
                preview = []
            }
        }
        var pairs: [(editor: CGFloat, preview: CGFloat)] = [(0, 0)]
        for (e, p) in zip(editor, preview) {
            guard let last = pairs.last, e.position > last.editor,
                  p.position > last.preview,
                  e.position < editorEnd, p.position < previewEnd
            else { continue }
            pairs.append((e.position, p.position))
        }
        pairs.append((max(editorEnd, pairs.last!.editor + 1),
                      max(previewEnd, pairs.last!.preview + 1)))
        self.pairs = pairs
    }

    private static func interpolate(
        _ x: CGFloat, _ points: [(CGFloat, CGFloat)]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        let upper = points.firstIndex { $0.0 > x }!
        let (x0, y0) = points[upper - 1]
        let (x1, y1) = points[upper]
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }

    public func previewPosition(forEditor position: CGFloat) -> CGFloat {
        Self.interpolate(position, pairs.map { ($0.editor, $0.preview) })
    }

    public func editorPosition(forPreview position: CGFloat) -> CGFloat {
        Self.interpolate(position, pairs.map { ($0.preview, $0.editor) })
    }

    /// Preview scroll offset matching an editor scroll offset.
    public func previewOffset(forEditorOffset offset: CGFloat,
                              editor: ScrollGeometry,
                              preview: ScrollGeometry) -> CGFloat {
        preview.offset(forFocus: previewPosition(forEditor: editor.focus(at: offset)))
    }

    /// Editor scroll offset matching a preview scroll offset.
    public func editorOffset(forPreviewOffset offset: CGFloat,
                             editor: ScrollGeometry,
                             preview: ScrollGeometry) -> CGFloat {
        editor.offset(forFocus: editorPosition(forPreview: preview.focus(at: offset)))
    }
}

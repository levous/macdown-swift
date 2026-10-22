//
//  ScrollSync.swift
//  MacDown
//
//  Scroll synchronization between the editor and the preview.
//
//  Both panes report "anchors": the preview marks every block with its
//  source line (`data-source-line`), and anchors are those lines (at the
//  block's top) in each pane, paired by line number. Pairs give a piecewise
//  linear map between editor and preview content positions. Each pane is
//  aligned at a focus line, which sits at the middle of the visible area,
//  except within the first and last screen of the document where it tapers
//  to the top and bottom edges, so both panes reach their top and bottom
//  together.
//

import Foundation

public struct ScrollAnchor: Sendable, Equatable {
    /// A 1-based source line.
    public var line: Int
    /// Where the line's block starts, in content coordinates.
    public var position: CGFloat

    public init(line: Int, _ position: CGFloat) {
        self.line = line
        self.position = position
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
        // Pair by line number, in preview order.
        var editorByLine: [Int: CGFloat] = [:]
        for anchor in editor where editorByLine[anchor.line] == nil {
            editorByLine[anchor.line] = anchor.position
        }
        let paired = preview.compactMap { anchor -> (ScrollAnchor, ScrollAnchor)? in
            guard let y = editorByLine[anchor.line] else { return nil }
            return (ScrollAnchor(line: anchor.line, y), anchor)
        }
        let editor = paired.map(\.0)
        let preview = paired.map(\.1)
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

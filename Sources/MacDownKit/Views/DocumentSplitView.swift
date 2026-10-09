//
//  DocumentSplitView.swift
//  MacDown
//
//  A two-pane split with a programmable divider position (HSplitView can't
//  be positioned programmatically). Replaces MPDocumentSplitView.
//

import AppKit
import SwiftUI

struct DocumentSplitView<Leading: View, Trailing: View>: View {
    /// Fraction of the width given to the leading pane.
    var fraction: CGFloat
    var dividerColor: Color?
    /// Backgrounds of the panes, which the divider's drag area extends.
    var leadingBackground: Color = .clear
    var trailingBackground: Color = .clear
    var onResize: (CGFloat) -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// Width of the divider's drag area, centered on the visible line. It
    /// sits between the panes rather than over them, so their views (the
    /// editor's text cursor, the web view) can't take the cursor or clicks.
    static var handleWidth: CGFloat { 8 }
    private let minimumPaneWidth: CGFloat = 80
    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let showsDivider = fraction > 0.001 && fraction < 0.999
            let handleWidth = showsDivider ? Self.handleWidth : 0
            let total = max(proxy.size.width - handleWidth, 0)
            let leadingWidth = (total * fraction).rounded()
            let trailingWidth = total - leadingWidth

            HStack(spacing: 0) {
                pane(leading, width: leadingWidth)
                if showsDivider {
                    SplitHandle(
                        lineColor: NSColor(dividerColor ?? Color(nsColor: .separatorColor)),
                        leadingColor: NSColor(leadingBackground),
                        trailingColor: NSColor(trailingBackground),
                        onDrag: { translation in drag(by: translation, total: total) },
                        onDragEnded: { dragStartFraction = nil })
                        .frame(width: handleWidth)
                }
                pane(trailing, width: trailingWidth)
            }
        }
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat) -> some View {
        content
            .frame(width: max(width, 0))
            .clipped()
            .opacity(width > 0 ? 1 : 0)
            .allowsHitTesting(width > 0)
            .accessibilityHidden(width <= 0)
    }

    private func drag(by translation: CGFloat, total: CGFloat) {
        guard total > 0 else { return }
        let start = dragStartFraction ?? fraction
        if dragStartFraction == nil { dragStartFraction = fraction }
        let minFraction = min(minimumPaneWidth / total, 0.5)
        onResize(min(max(start + translation / total, minFraction), 1 - minFraction))
    }
}

/// The divider's drag area, drawn as the panes' backgrounds with a line in
/// the middle.
struct SplitHandle: NSViewRepresentable {
    var lineColor: NSColor
    var leadingColor: NSColor
    var trailingColor: NSColor
    /// Called with the horizontal distance dragged since the mouse went down.
    var onDrag: (CGFloat) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> SplitHandleView {
        SplitHandleView()
    }

    func updateNSView(_ view: SplitHandleView, context: Context) {
        view.lineColor = lineColor
        view.leadingColor = leadingColor
        view.trailingColor = trailingColor
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
    }
}

final class SplitHandleView: NSView {
    var lineColor: NSColor = .separatorColor { didSet { needsDisplay = true } }
    var leadingColor: NSColor = .clear { didSet { needsDisplay = true } }
    var trailingColor: NSColor = .clear { didSet { needsDisplay = true } }
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat?

    static let lineWidth: CGFloat = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let lineX = (bounds.midX - Self.lineWidth / 2).rounded()
        leadingColor.setFill()
        NSRect(x: 0, y: 0, width: lineX, height: bounds.height).fill()
        trailingColor.setFill()
        NSRect(x: lineX + Self.lineWidth, y: 0,
               width: bounds.width - lineX - Self.lineWidth, height: bounds.height).fill()
        lineColor.setFill()
        NSRect(x: lineX, y: 0, width: Self.lineWidth, height: bounds.height).fill()
    }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.columnResize.set()
    }

    // MARK: Dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        // Keep the resize cursor while the pointer runs ahead of the divider
        // over the panes.
        window?.disableCursorRects()
        NSCursor.columnResize.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        NSCursor.columnResize.set()
        onDrag?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: self)
        onDragEnded?()
    }
}

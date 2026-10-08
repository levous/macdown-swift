//
//  DocumentSplitView.swift
//  MacDown
//
//  A two-pane split with a programmable divider position (HSplitView can't
//  be positioned programmatically). Replaces MPDocumentSplitView.
//

import SwiftUI

struct DocumentSplitView<Leading: View, Trailing: View>: View {
    /// Fraction of the width given to the leading pane.
    var fraction: CGFloat
    var dividerColor: Color?
    var onResize: (CGFloat) -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    private let dividerWidth: CGFloat = 1
    private let minimumPaneWidth: CGFloat = 80
    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let total = max(proxy.size.width - dividerWidth, 0)
            let leadingWidth = (total * fraction).rounded()
            let trailingWidth = total - leadingWidth
            let showsDivider = leadingWidth > 0 && trailingWidth > 0

            HStack(spacing: 0) {
                pane(leading, width: leadingWidth)
                divider(total: total)
                    .frame(width: dividerWidth)
                    .opacity(showsDivider ? 1 : 0)
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

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(dividerColor ?? Color(nsColor: .separatorColor))
            .overlay {
                // A wider, invisible drag handle.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.columnResize.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStartFraction ?? fraction
                                if dragStartFraction == nil { dragStartFraction = fraction }
                                var new = start + value.translation.width / total
                                let minFraction = minimumPaneWidth / total
                                new = min(max(new, minFraction), 1 - minFraction)
                                onResize(new)
                            }
                            .onEnded { _ in dragStartFraction = nil }
                    )
            }
    }
}

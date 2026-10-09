//
//  SplitViewTests.swift
//  MacDownKitTests
//

import AppKit
import SwiftUI
import Testing
@testable import MacDownKit

/// Stands in for a pane's AppKit view (the editor or the web view).
private struct PaneView: NSViewRepresentable {
    var textView = false
    func makeNSView(context: Context) -> NSView {
        textView ? NSTextView() : NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor @Suite struct SplitViewTests {
    final class Recorder {
        var fractions: [CGFloat] = []
    }

    func makeWindow(fraction: CGFloat, recorder: Recorder) -> (NSWindow, NSHostingView<AnyView>) {
        let split = DocumentSplitView(
            fraction: fraction,
            onResize: { recorder.fractions.append($0) }
        ) {
            PaneView(textView: true)
        } trailing: {
            PaneView()
        }
        let host = NSHostingView(rootView: AnyView(split))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 808, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    func handle(in view: NSView) -> SplitHandleView? {
        if let handle = view as? SplitHandleView { return handle }
        for subview in view.subviews {
            if let handle = handle(in: subview) { return handle }
        }
        return nil
    }

    @Test func dragAreaIsCenteredOnTheDivider() throws {
        let (window, host) = makeWindow(fraction: 0.5, recorder: Recorder())
        defer { window.close() }
        let handle = try #require(handle(in: host))
        let frame = handle.convert(handle.bounds, to: nil)
        // 808 wide minus the 8 point handle leaves 400 for each pane.
        #expect(frame.minX == 400)
        #expect(frame.width == DocumentSplitView<EmptyView, EmptyView>.handleWidth)

        // Either side of the line, the handle gets the mouse, not the panes.
        let lineX = frame.midX
        for x in [lineX - 3.5, lineX, lineX + 3.5] {
            let point = host.convert(NSPoint(x: x, y: 200), from: nil)
            let hit = host.hitTest(point)
            #expect(hit === handle, "x = \(x) hit \(String(describing: hit))")
        }
        // Just outside it, the panes do.
        for x in [frame.minX - 1, frame.maxX + 1] {
            let point = host.convert(NSPoint(x: x, y: 200), from: nil)
            #expect(host.hitTest(point) !== handle)
        }
    }

    @Test func handleShowsTheResizeCursor() throws {
        let (window, host) = makeWindow(fraction: 0.5, recorder: Recorder())
        defer { window.close() }
        let handle = try #require(handle(in: host))
        NSCursor.iBeam.set()
        handle.cursorUpdate(with: try #require(NSEvent.enterExitEvent(
            with: .cursorUpdate, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)))
        #expect(NSCursor.current == NSCursor.columnResize)
        handle.updateTrackingAreas()
        #expect(handle.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
    }

    @Test func draggingResizes() throws {
        let recorder = Recorder()
        let (window, host) = makeWindow(fraction: 0.5, recorder: recorder)
        defer { window.close() }
        let handle = try #require(handle(in: host))
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 200), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try mouse(.leftMouseDown, x: 404))
        NSCursor.iBeam.set()
        handle.mouseDragged(with: try mouse(.leftMouseDragged, x: 484))
        // The resize cursor stays while dragging, even over the panes.
        #expect(NSCursor.current == NSCursor.columnResize)
        handle.mouseUp(with: try mouse(.leftMouseUp, x: 484))
        // 80 points of the 800 shared by the panes.
        let fraction = try #require(recorder.fractions.last)
        #expect(abs(fraction - 0.6) < 0.0001)
    }
}

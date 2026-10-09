//
//  Representables.swift
//  MacDown
//
//  Bridges the AppKit editor and WebKit preview into SwiftUI.
//

import AppKit
import SwiftUI
import WebKit

struct EditorRepresentable: NSViewRepresentable {
    let controller: DocumentController

    func makeNSView(context: Context) -> NSScrollView {
        controller.editorScrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

struct PreviewRepresentable: NSViewRepresentable {
    let controller: DocumentController

    func makeNSView(context: Context) -> WKWebView {
        controller.preview.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

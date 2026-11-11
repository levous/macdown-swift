//
//  ExportedPageLayoutTests.swift
//  MacDownKitTests
//
//  How exported pages lay out in a real WebKit view, at phone width.
//

import Foundation
import Testing
import WebKit
@testable import MacDownKit

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, any Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@Suite @MainActor struct ExportedPageLayoutTests {
    /// Viewers such as a phone's file preview may not run scripts, so Prism
    /// never adds its class to the `pre`. Long lines must still scroll inside
    /// the block instead of running past its background.
    @Test func longCodeLinesStayInsideTheBlockWithoutScripts() async throws {
        var settings = PageSettings()
        settings.styleName = "Solarized (Light)"
        settings.syntaxHighlighting = true
        let line = String(repeating: "a long line of lyrics ", count: 10)
        let html = PageBuilder.exportHTML(
            title: nil,
            result: ParseResult(body: "<div><pre><code class=\"language-none\">\(line)</code></pre></div>", languages: []),
            settings: settings, withStyles: true, withHighlighting: true)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        let json = try await webView.evaluateJavaScript("""
            (() => {
                const pre = document.querySelector("pre");
                return JSON.stringify({
                    preClass: pre.className,
                    overflow: getComputedStyle(pre).overflowX,
                    preWidth: pre.clientWidth,
                    contentWidth: pre.scrollWidth,
                    pageWidth: document.documentElement.scrollWidth,
                    windowWidth: window.innerWidth,
                });
            })()
            """) as? String
        struct Layout: Decodable {
            var preClass: String
            var overflow: String
            var preWidth: Int
            var contentWidth: Int
            var pageWidth: Int
            var windowWidth: Int
        }
        let layout = try JSONDecoder().decode(Layout.self, from: Data(try #require(json).utf8))

        #expect(layout.preClass.isEmpty, "Prism's script ran")
        #expect(layout.contentWidth > layout.preWidth, "the line should be too long to fit")
        #expect(layout.overflow == "auto")
        #expect(layout.pageWidth <= layout.windowWidth)
    }
}

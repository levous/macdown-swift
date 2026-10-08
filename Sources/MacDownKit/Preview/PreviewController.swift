//
//  PreviewController.swift
//  MacDown
//
//  Owns the preview WKWebView. Replaces the WebView delegates in MPDocument.m
//  with public WebKit API: navigation policy, script messages for MathJax,
//  JavaScript for word count and scroll synchronization.
//

import AppKit
import WebKit

/// A web view that ignores drops (like the original preview).
final class PreviewWebView: WKWebView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        false
    }
}

public struct TextCount: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersNoSpaces = 0
}

public struct PreviewMetrics: Sendable {
    /// Scroll sync anchors, in CSS pixels; see `ScrollAnchors`.
    public var anchors: [ScrollAnchor] = []
    public var contentHeight: CGFloat = 0
    public var visibleHeight: CGFloat = 0

    public var geometry: ScrollGeometry {
        ScrollGeometry(contentHeight: contentHeight, visibleHeight: visibleHeight)
    }
}

@MainActor
public final class PreviewController: NSObject {
    public let webView: WKWebView

    /// Called when a load finishes (after MathJax typesetting, if enabled).
    public var onLoadFinished: (() -> Void)?
    /// Called for link clicks that leave the current document.
    public var onOpenURL: ((URL) -> Void)?
    /// Called when the page scrolls, with the new offset in CSS pixels.
    public var onScroll: ((CGFloat) -> Void)?
    /// Called when the page's layout changes after loading, e.g. because
    /// the view was resized or an image finished loading.
    public var onLayoutChange: (() -> Void)?

    public private(set) var isLoading = false
    public private(set) var isReady = false
    public private(set) var currentBaseURL: URL?
    public private(set) var lastScrollTop: CGFloat = 0

    private var waitsForMathJax = false
    /// The loaded page without its body; see `load(html:...)`.
    private var loadedShell: String?
    private var loadingShell: String?
    private let messageProxy = MessageProxy()

    /// The hidden preference that adds "Inspect Element" to the preview's
    /// context menu. WebView read it itself; WKWebView has to be told.
    static let developerExtrasKey = "WebKitDeveloperExtras"

    static var isInspectable: Bool {
        UserDefaults.standard.bool(forKey: developerExtrasKey)
    }

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(),
                                          forURLScheme: PreviewURL.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        let controller = configuration.userContentController
        controller.add(messageProxy, name: "MathJaxListener")
        controller.add(messageProxy, name: "MacDownScroll")
        controller.add(messageProxy, name: "MacDownLayout")
        controller.addUserScript(WKUserScript(
            source: Self.scrollReporterScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))

        webView = PreviewWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.isInspectable = Self.isInspectable
        messageProxy.owner = self
    }

    // MARK: - Loading

    /// Loads a complete HTML page.
    ///
    /// When only the body differs from the page already loaded (the page
    /// was made by `PageBuilder.previewHTML`, and its styles, scripts and
    /// base URL are unchanged), the body is replaced in place, keeping the
    /// scroll position and avoiding a flash of the top of the page.
    ///
    /// - Parameters:
    ///   - baseURL: The document's file URL (or a directory for unsaved
    ///     documents). Relative links resolve against it.
    ///   - restoresScroll: Whether to restore the current scroll position as
    ///     early as possible in the new page.
    public func load(html: String, baseURL: URL?, waitForMathJax: Bool,
                     restoresScroll: Bool) {
        let parts = Self.splitBody(html)
        let shell = parts?.shell
        if let parts, isReady, !isLoading, shell == loadedShell,
           baseURL == currentBaseURL {
            replaceBody(parts.body, orLoad: html, baseURL: baseURL,
                        waitForMathJax: waitForMathJax, restoresScroll: restoresScroll)
            return
        }
        loadPage(html, baseURL: baseURL, waitForMathJax: waitForMathJax,
                 restoresScroll: restoresScroll)
    }

    private func loadPage(_ html: String, baseURL: URL?, waitForMathJax: Bool,
                          restoresScroll: Bool) {
        var html = html
        if restoresScroll, lastScrollTop > 0 {
            let restore = "<script>window.scrollTo(0, \(lastScrollTop));</script>"
            if let range = html.range(of: "</body>", options: .backwards) {
                html.insert(contentsOf: restore, at: range.lowerBound)
            } else {
                html += restore
            }
        }
        isLoading = true
        waitsForMathJax = waitForMathJax
        currentBaseURL = baseURL
        // Not known to be in place until the navigation finishes.
        loadedShell = nil
        loadingShell = Self.splitBody(html)?.shell
        let base = baseURL.map(PreviewURL.previewURL(for:))
        webView.loadHTMLString(html, baseURL: base)
    }

    /// The page without its body, and the body, split at the markers added by
    /// `PageBuilder.previewHTML`.
    static func splitBody(_ html: String) -> (shell: String, body: String)? {
        guard let start = html.range(of: PageBuilder.previewBodyStart),
              let end = html.range(of: PageBuilder.previewBodyEnd, options: .backwards),
              start.upperBound <= end.lowerBound
        else { return nil }
        return (String(html[..<start.upperBound]) + String(html[end.lowerBound...]),
                String(html[start.upperBound..<end.lowerBound]))
    }

    private func replaceBody(_ body: String, orLoad html: String, baseURL: URL?,
                             waitForMathJax: Bool, restoresScroll: Bool) {
        isLoading = true
        waitsForMathJax = false
        webView.callAsyncJavaScript(
            Self.replaceBodyScript,
            arguments: ["html": body,
                        "startMarker": Self.markerText(PageBuilder.previewBodyStart),
                        "endMarker": Self.markerText(PageBuilder.previewBodyEnd),
                        "mathJax": waitForMathJax],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, let y = value as? NSNumber,
               y.doubleValue >= 0 {
                self.lastScrollTop = CGFloat(y.doubleValue)
                self.finishLoading()
            } else {
                // The page isn't what we thought it was; start over.
                self.loadPage(html, baseURL: baseURL, waitForMathJax: waitForMathJax,
                              restoresScroll: restoresScroll)
            }
        }
    }

    private static func markerText(_ comment: String) -> String {
        String(comment.dropFirst(4).dropLast(3))    // Strip "<!--" and "-->".
    }

    /// Replaces the nodes between the body markers, then does what loading
    /// the page would: highlights code, draws Mermaid diagrams, runs `load`
    /// handlers (Graphviz), disables task list checkboxes (tasklist.js) and typesets
    /// math. Resolves to the scroll offset once images have loaded, so
    /// metrics are final, or to -1 if the markers are missing.
    private static let replaceBodyScript = """
        var start = null, end = null;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_COMMENT);
        for (var node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.data === startMarker && !start) start = node;
          if (node.data === endMarker) end = node;
        }
        if (!start || !end || start.parentNode !== end.parentNode) return -1;

        // Keep the page as tall as it was while the new content settles, so
        // the scroll position isn't clamped.
        var y = window.scrollY;
        var body = document.body;
        body.style.minHeight = document.documentElement.scrollHeight + "px";
        while (start.nextSibling && start.nextSibling !== end) {
          start.parentNode.removeChild(start.nextSibling);
        }
        var range = document.createRange();
        range.setStartAfter(start);
        start.parentNode.insertBefore(range.createContextualFragment(html), end);
        window.scrollTo(window.scrollX, y);

        if (window.Prism) Prism.highlightAll();
        if (window.MacDownMermaid) await MacDownMermaid.render();
        // Graphviz renders from a load handler; other load listeners
        // (MathJax's startup) shouldn't run twice.
        if (window.Viz) window.dispatchEvent(new Event("load"));
        Array.prototype.forEach.call(
          document.getElementsByClassName("task-list-item"), function (item) {
            var input = item.getElementsByTagName("input")[0];
            if (input) input.disabled = true;
          });
        if (mathJax && window.MathJax && MathJax.Hub) {
          await new Promise(function (resolve) {
            MathJax.Hub.Queue(["Typeset", MathJax.Hub], resolve);
          });
        }
        var pending = Array.prototype.filter.call(document.images, function (image) {
          return !image.complete;
        });
        await Promise.race([
          Promise.all(pending.map(function (image) {
            return new Promise(function (resolve) {
              image.addEventListener("load", resolve, { once: true });
              image.addEventListener("error", resolve, { once: true });
            });
          })),
          // Don't hold up typing for slow images; the layout observer
          // reports them when they arrive.
          new Promise(function (resolve) { setTimeout(resolve, 150); })
        ]);
        body.style.minHeight = "";
        return window.scrollY;
        """

    private func finishLoading() {
        isLoading = false
        isReady = true
        onLoadFinished?()
    }

    // MARK: - JavaScript helpers

    public func scroll(to y: CGFloat) {
        webView.evaluateJavaScript("window.scrollTo(0, \(y));", completionHandler: nil)
    }

    public func restoreScrollPosition() {
        scroll(to: lastScrollTop)
    }

    public func fetchMetrics() async -> PreviewMetrics {
        // Mirrors ScrollAnchors.scan: top-level headers, and images in
        // top-level paragraphs that contain nothing else.
        let script = """
            (function () {
              var anchors = [];
              function add(kind, node) {
                var rect = node.getBoundingClientRect();
                anchors.push([kind, rect.top + window.scrollY + rect.height / 2]);
              }
              // The body, unless a custom template wraps it.
              var first = document.querySelector("h1, h2, h3, h4, h5, h6, p");
              var container = (first && first.parentElement) || document.body;
              Array.prototype.forEach.call(container.children, function (node) {
                if (/^H[1-6]$/.test(node.tagName)) {
                  add("h", node);
                } else if (node.tagName === "P" && node.textContent.trim() === ""
                           && node.querySelector("img")) {
                  var children = Array.prototype.slice.call(node.children);
                  if (children.every(function (c) {
                        return c.tagName === "IMG" || c.tagName === "BR"; })) {
                    children.forEach(function (c) {
                      if (c.tagName === "IMG") add("i", c);
                    });
                  }
                }
              });
              return JSON.stringify({
                anchors: anchors,
                contentHeight: document.documentElement.scrollHeight,
                visibleHeight: window.innerHeight
              });
            })();
            """
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return PreviewMetrics() }
        var metrics = PreviewMetrics()
        metrics.anchors = (object["anchors"] as? [[Any]] ?? []).compactMap {
            guard $0.count == 2, let kind = $0[0] as? String,
                  let y = $0[1] as? NSNumber else { return nil }
            return ScrollAnchor(kind == "h" ? .header : .image, CGFloat(y.doubleValue))
        }
        metrics.contentHeight = CGFloat((object["contentHeight"] as? NSNumber)?
            .doubleValue ?? 0)
        metrics.visibleHeight = CGFloat((object["visibleHeight"] as? NSNumber)?
            .doubleValue ?? 0)
        return metrics
    }

    /// Counts words and characters in the rendered page, following the rules
    /// of the original DOMNode+Text: script, style and head content is
    /// ignored; code blocks are excluded from the word count, and inline code
    /// counts as one word.
    public func fetchTextCount() async -> TextCount {
        let script = """
            (function () {
              var words = [], codes = [], texts = [];
              function walk(node, inCode) {
                for (var c = node.firstChild; c; c = c.nextSibling) {
                  if (c.nodeType === 1) {
                    var tag = c.tagName.toUpperCase();
                    if (tag === "SCRIPT" || tag === "STYLE" || tag === "HEAD") continue;
                    if (tag === "CODE") {
                      var block = c.parentElement && c.parentElement.tagName === "PRE";
                      if (!block) codes.push(c.textContent);
                      walkTexts(c);
                      continue;
                    }
                    walk(c, inCode);
                  } else if (c.nodeType === 3 || c.nodeType === 4) {
                    words.push(c.nodeValue);
                    texts.push(c.nodeValue);
                  }
                }
              }
              function walkTexts(node) {
                for (var c = node.firstChild; c; c = c.nextSibling) {
                  if (c.nodeType === 1) {
                    var tag = c.tagName.toUpperCase();
                    if (tag === "SCRIPT" || tag === "STYLE" || tag === "HEAD") continue;
                    walkTexts(c);
                  } else if (c.nodeType === 3 || c.nodeType === 4) {
                    texts.push(c.nodeValue);
                  }
                }
              }
              walk(document, false);
              return JSON.stringify({ words: words, codes: codes, texts: texts });
            })();
            """
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: [String]]
        else { return TextCount() }

        var count = TextCount()
        for text in object["words"] ?? [] {
            count.words += text.numberOfWords
        }
        for code in object["codes"] ?? [] where code.numberOfWords > 0 {
            count.words += 1
        }
        for text in object["texts"] ?? [] {
            count.characters += text.lengthWithoutNewlines
            count.charactersNoSpaces += text.lengthWithoutWhitespacesAndNewlines
        }
        return count
    }

    /// The computed background color of the page body.
    public func fetchBackgroundColor() async -> NSColor? {
        let script = "getComputedStyle(document.body).backgroundColor"
        guard let value = try? await webView.evaluateJavaScript(script) as? String
        else { return nil }
        return NSColor(htmlName: value)
    }

    // MARK: - Printing

    public func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        return operation
    }

    // MARK: - Messages

    func pageDidScroll(to y: CGFloat) {
        lastScrollTop = y
        if !isLoading { onScroll?(y) }
    }

    func pageLayoutDidChange() {
        if !isLoading { onLayoutChange?() }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        switch message.name {
        case "MathJaxListener":
            if waitsForMathJax, (message.body as? String) == "End" {
                waitsForMathJax = false
                finishLoading()
            }
        case "MacDownScroll":
            if let y = message.body as? NSNumber {
                pageDidScroll(to: CGFloat(y.doubleValue))
            }
        case "MacDownLayout":
            pageLayoutDidChange()
        default:
            break
        }
    }

    static let scrollReporterScript = """
        (function () {
          var pending = false;
          window.addEventListener("scroll", function () {
            if (pending) return;
            pending = true;
            window.requestAnimationFrame(function () {
              pending = false;
              window.webkit.messageHandlers.MacDownScroll.postMessage(window.scrollY);
            });
          }, { passive: true });

          // Report layout changes: resizing reflows text and scales images,
          // and images may finish loading late.
          var layoutPending = false;
          var lastWidth = -1, lastHeight = -1;
          function reportLayout() {
            if (layoutPending) return;
            layoutPending = true;
            window.requestAnimationFrame(function () {
              layoutPending = false;
              var width = window.innerWidth;
              var height = document.documentElement.scrollHeight;
              if (width === lastWidth && height === lastHeight) return;
              lastWidth = width;
              lastHeight = height;
              window.webkit.messageHandlers.MacDownLayout.postMessage(height);
            });
          }
          window.addEventListener("resize", reportLayout);
          document.addEventListener("load", reportLayout, true);
          if (window.ResizeObserver && document.body) {
            new ResizeObserver(reportLayout).observe(document.body);
          }
        })();
        """
}

extension PreviewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedShell = loadingShell
        // If MathJax is on, completion is reported by its script handler.
        if !waitsForMathJax {
            finishLoading()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: any Error) {
        waitsForMathJax = false
        finishLoading()
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        waitsForMathJax = false
        finishLoading()
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction)
        async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else { return .allow }
        let target = PreviewURL.fileURL(for: url)

        // If the target is exactly the current page, ignore.
        if let currentBaseURL, target == currentBaseURL {
            return .cancel
        }
        // If this is a different page, intercept and handle ourselves.
        if !isCurrentBase(target) {
            onOpenURL?(target)
            return .cancel
        }
        // Otherwise this is somewhere else on the same page. Jump there.
        return .allow
    }

    private func isCurrentBase(_ url: URL) -> Bool {
        func base(_ url: URL?) -> String? {
            guard let string = url?.absoluteString else { return nil }
            return string.components(separatedBy: "?").first?
                .components(separatedBy: "#").first
        }
        return base(currentBaseURL) == base(url)
    }
}

/// Avoids a retain cycle between the user content controller and the
/// preview controller.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            owner?.receive(message)
        }
    }
}

extension String {
    var numberOfWords: Int {
        var count = 0
        enumerateSubstrings(in: startIndex..<endIndex,
                            options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    var lengthWithoutNewlines: Int {
        components(separatedBy: .newlines).reduce(0) { $0 + ($1 as NSString).length }
    }

    var lengthWithoutWhitespacesAndNewlines: Int {
        components(separatedBy: .whitespacesAndNewlines)
            .reduce(0) { $0 + ($1 as NSString).length }
    }
}

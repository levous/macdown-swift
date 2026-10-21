//
//  PasteboardContentTests.swift
//  MacDownKitTests
//
//  What a paste finds on the clipboard (paste intent, FR-1 to FR-3, FR-25,
//  FR-33). Each test uses its own named pasteboard, not the user's.
//

import AppKit
import Testing
@testable import MacDownKit

@MainActor @Suite struct PasteboardContentTests {
    /// A private pasteboard holding `types`.
    func pasteboard(_ types: [NSPasteboard.PasteboardType: Data]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("MacDownTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    func read(_ types: [NSPasteboard.PasteboardType: Data]) -> PasteboardContent? {
        let pasteboard = pasteboard(types)
        defer { pasteboard.releaseGlobally() }
        return PasteboardContent.read(from: pasteboard)
    }

    @Test func html() {
        #expect(read([.html: Data("<p><b>x</b></p>".utf8), .string: Data("x".utf8)])
                    == .html("<p><b>x</b></p>", baseURL: nil))
    }

    @Test func sourceURLs() {
        let html = Data("<p>x</p>".utf8)
        #expect(read([.html: html, .init("org.chromium.source-url"): Data("https://e.com/a/b.html".utf8)])
                    == .html("<p>x</p>", baseURL: URL(string: "https://e.com/a/b.html")))
        #expect(read([.html: html, .URL: Data("https://e.com/c".utf8)])
                    == .html("<p>x</p>", baseURL: URL(string: "https://e.com/c")))
    }

    /// The page's own base wins, resolved against where it came from.
    @Test func baseElement() {
        let html = #"<html><head><base href="../docs/"></head><body><p>x</p></body></html>"#
        #expect(read([.html: Data(html.utf8), .init("org.chromium.source-url"): Data("https://e.com/a/b.html".utf8)])
                    == .html(html, baseURL: URL(string: "https://e.com/docs/")))
    }

    /// WebKit (Safari, MacDown's preview) writes a web archive with the
    /// page's address.
    @Test func webArchive() throws {
        let resource: [String: Any] = ["WebResourceData": Data("<p>archived</p>".utf8),
                                       "WebResourceURL": "https://e.com/page.html",
                                       "WebResourceMIMEType": "text/html",
                                       "WebResourceTextEncodingName": "UTF-8", "WebResourceFrameName": ""]
        let archive = try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": resource],
                                                         format: .binary, options: 0)
        #expect(read([.init("com.apple.webarchive"): archive, .string: Data("archived".utf8)])
                    == .html("<p>archived</p>", baseURL: URL(string: "https://e.com/page.html")))
        // With HTML too, the HTML is used and the archive gives its address.
        #expect(read([.html: Data("<p>h</p>".utf8), .init("com.apple.webarchive"): archive])
                    == .html("<p>h</p>", baseURL: URL(string: "https://e.com/page.html")))
    }

    /// Rich text becomes HTML through AppKit's export.
    @Test func richText() throws {
        let text = NSMutableAttributedString(string: "plain ", attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        text.append(NSAttributedString(string: "bold", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!]))
        let rtf = try #require(text.rtf(from: NSRange(location: 0, length: text.length)))
        guard case .html(let html, nil)? = read([.rtf: rtf, .string: Data("plain bold".utf8)]) else {
            Issue.record("no HTML")
            return
        }
        #expect(HTMLToMarkdown(options: pasteTestOptions).convert(html)?.markdown == "plain **bold**")
        let rtfd = try #require(text.rtfd(from: NSRange(location: 0, length: text.length)))
        guard case .html(let fromRTFD, nil)? = read([.rtfd: rtfd]) else {
            Issue.record("no HTML from RTFD")
            return
        }
        #expect(HTMLToMarkdown(options: pasteTestOptions).convert(fromRTFD)?.markdown == "plain **bold**")
    }

    @Test func imageData() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let jpeg = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        #expect(read([.png: png]) == .image(png, mime: "image/png"))
        #expect(read([.init("public.jpeg"): jpeg]) == .image(jpeg, mime: "image/jpeg"))
        // Screenshots and many apps write TIFF, which becomes PNG.
        guard case .image(let converted, "image/png")? = read([.tiff: tiff]) else {
            Issue.record("TIFF wasn't converted")
            return
        }
        #expect(converted.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// Text on the clipboard wins over an image (a file copied in Finder
    /// has its icon too), and plain text alone is left to the text view.
    @Test func plainText() {
        #expect(read([.string: Data("text".utf8)]) == nil)
        #expect(read([.png: Data([0x89, 0x50]), .string: Data("name.png".utf8)]) == nil)
        #expect(read([:]) == nil)
        // A file dragged from the Finder, with its icon.
        #expect(read([.fileURL: Data("file:///tmp/a.txt".utf8), .tiff: Data([0x4D, 0x4D])]) == nil)
    }
}

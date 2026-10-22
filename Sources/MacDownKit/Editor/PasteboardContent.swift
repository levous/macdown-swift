//
//  PasteboardContent.swift
//  MacDown
//
//  What a paste can convert: formatted text as HTML, with the address it
//  came from, or an image. Plain text is left to the text view.
//

import AppKit

enum PasteboardContent: Equatable {
    /// HTML, and what its relative links resolve against.
    case html(String, baseURL: URL?)
    /// Image data, as PNG or JPEG.
    case image(Data, mime: String)

    static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
    static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    /// The clipboard's formatted text or image, in order of preference:
    /// HTML (or a web archive), then rich text, then image
    /// data when there's no text at all. Nil for plain text.
    @MainActor static func read(from pasteboard: NSPasteboard) -> PasteboardContent? {
        let types = pasteboard.types ?? []
        let archive = types.contains(webArchive) ? pasteboard.data(forType: webArchive).flatMap(mainResource) : nil
        if let html = pasteboard.string(forType: .html) ?? archive?.html {
            return .html(html, baseURL: baseURL(of: html, source: sourceURL(pasteboard) ?? archive?.url))
        }
        for type in [NSPasteboard.PasteboardType.rtf, .rtfd] where types.contains(type) {
            if let data = pasteboard.data(forType: type), let html = html(fromRichText: data, type: type) {
                return .html(html, baseURL: nil)
            }
        }
        // Text wins over an image, and a file dragged from the Finder
        // carries its icon.
        guard !types.contains(.string), !types.contains(.fileURL) else { return nil }
        if let png = pasteboard.data(forType: .png) { return .image(png, mime: "image/png") }
        if let jpeg = pasteboard.data(forType: jpeg) { return .image(jpeg, mime: "image/jpeg") }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return .image(png, mime: "image/png")
        }
        return nil
    }

    /// The page the clipboard's HTML was copied from, as browsers note it.
    private static func sourceURL(_ pasteboard: NSPasteboard) -> URL? {
        for type in [chromiumSourceURL, .URL] {
            if let string = pasteboard.string(forType: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: string), url.scheme != nil {
                return url
            }
        }
        return nil
    }

    private static let baseElement = try! NSRegularExpression(
        pattern: #"<base\s[^>]*href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)

    /// What relative URLs in `html` resolve against: its `<base href>`,
    /// itself resolved against the source, or the source.
    static func baseURL(of html: String, source: URL?) -> URL? {
        guard let match = baseElement.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let base = URL(string: String(html[range]), relativeTo: source)?.absoluteURL
        else { return source }
        return base
    }

    /// A web archive's main page: its HTML and address.
    private static func mainResource(_ data: Data) -> (html: String, url: URL?)? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let resource = archive["WebMainResource"] as? [String: Any],
              let bytes = resource["WebResourceData"] as? Data
        else { return nil }
        let html = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        return (html, (resource["WebResourceURL"] as? String).flatMap(URL.init(string:)))
    }

    /// Rich text as HTML, through AppKit's export (Cocoa HTML Writer).
    private static func html(fromRichText data: Data, type: NSPasteboard.PasteboardType) -> String? {
        let text = type == .rtfd
            ? NSAttributedString(rtfd: data, documentAttributes: nil)
            : NSAttributedString(rtf: data, documentAttributes: nil)
        guard let text, text.length > 0,
              let html = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        else { return nil }
        return String(decoding: html, as: UTF8.self)
    }
}

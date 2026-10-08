//
//  LocalFileSchemeHandler.swift
//  MacDown
//
//  WKWebView restricts file:// access for pages loaded from strings, so the
//  preview is served through a custom scheme that maps directly onto the
//  local file system:
//
//      x-macdown-preview://local/Users/me/notes/doc.md
//
//  Relative links and images in the document resolve against the document's
//  own (mapped) URL, and stylesheets and scripts are linked the same way.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

public enum PreviewURL {
    public static let scheme = "x-macdown-preview"
    static let host = "local"

    /// Maps a file URL to its preview URL. Other URLs are returned unchanged.
    public static func previewURL(for url: URL) -> URL {
        guard url.isFileURL else { return url }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var path = url.path
        if url.hasDirectoryPath && !path.hasSuffix("/") {
            path += "/"
        }
        components.path = path
        return components.url ?? url
    }

    /// Maps a preview URL back to a file URL. Other URLs are returned
    /// unchanged.
    public static func fileURL(for url: URL) -> URL {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return url }
        var fileComponents = URLComponents()
        fileComponents.scheme = "file"
        fileComponents.path = components.path
        fileComponents.query = components.query
        fileComponents.fragment = components.fragment
        return fileComponents.url ?? url
    }
}

final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let fileURL = PreviewURL.fileURL(for: url)
        do {
            let data = try Data(contentsOf: fileURL)
            let mime = UTType(filenameExtension: fileURL.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                ])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            let response = HTTPURLResponse(url: url, statusCode: 404,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

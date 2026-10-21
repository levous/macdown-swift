//
//  ImageMarkup.swift
//  MacDown
//
//  Images embedded in the document as data URIs: image files dropped on the
//  editor, and image data pasted into it (paste intent, FR-33).
//

import Foundation
import UniformTypeIdentifiers

enum ImageMarkup {
    /// `![](data:<mime>;base64,…)`.
    static func dataURI(_ data: Data, mime: String) -> String {
        "![](data:\(mime);base64,\(data.base64EncodedString()))"
    }

    /// The markup for an image file, typed by its extension (JPEG if it
    /// has none MacDown knows), or nil if it can't be read.
    static func dataURI(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        return dataURI(data, mime: mime)
    }
}

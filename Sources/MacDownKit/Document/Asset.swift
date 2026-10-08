//
//  Asset.swift
//  MacDown
//
//  Ported from MPAsset.m.
//

import Foundation

public enum AssetOption: Sendable {
    /// The asset is not included.
    case none
    /// The asset's content is embedded in the HTML (file URLs only).
    case embedded
    /// The asset is linked with its URL.
    case fullLink
}

public enum AssetType {
    public static let plain = "text/plain"
    public static let css = "text/css"
    public static let javaScript = "text/javascript"
    public static let mathJaxConfig = "text/x-mathjax-config"
}

public struct Asset: Sendable, Equatable {
    public enum Kind: Sendable {
        case styleSheet
        case script
        /// A script that is always embedded, even when linking is requested.
        case embeddedScript
    }

    public var url: URL?
    public var typeName: String
    public var kind: Kind

    public static func css(_ url: URL?) -> Asset {
        Asset(url: url, typeName: AssetType.css, kind: .styleSheet)
    }

    public static func javaScript(_ url: URL?) -> Asset {
        Asset(url: url, typeName: AssetType.javaScript, kind: .script)
    }

    public static func embeddedScript(_ url: URL?, type: String) -> Asset {
        Asset(url: url, typeName: type, kind: .embeddedScript)
    }

    /// Produces the HTML tag for this asset.
    ///
    /// - Parameter linkTransform: Maps file URLs to the URL used in the
    ///   generated link. The preview uses this to serve local files through
    ///   its custom URL scheme.
    public func html(for option: AssetOption,
                     linkTransform: (URL) -> URL = { $0 }) -> String? {
        var option = option
        if kind == .embeddedScript && option == .fullLink {
            option = .embedded
        }
        guard let url else { return nil }

        switch option {
        case .none:
            return nil
        case .embedded where url.isFileURL:
            var content = MPPaths.readFile(at: url)
            if content.hasSuffix("\n") {
                content.removeLast()
            }
            let type = MPEscapeHTML(typeName)
            switch kind {
            case .styleSheet:
                return "<style type=\"\(type)\">\n\(content)\n</style>"
            case .script, .embeddedScript:
                return "<script type=\"\(type)\">\n\(content)\n</script>"
            }
        case .embedded, .fullLink:
            // Non-file URLs are always treated as full links.
            let link = MPEscapeHTML(linkTransform(url).absoluteString)
            let type = MPEscapeHTML(typeName)
            switch kind {
            case .styleSheet:
                return "<link rel=\"stylesheet\" type=\"\(type)\" href=\"\(link)\">"
            case .script, .embeddedScript:
                return "<script type=\"\(type)\" src=\"\(link)\"></script>"
            }
        }
    }
}

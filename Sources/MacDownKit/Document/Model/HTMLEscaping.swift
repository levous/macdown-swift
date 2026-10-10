//
//  HTMLEscaping.swift
//  MacDownKit
//
//  HTML and URL escaping for the cmark-gfm renderer, matching hoedown's
//  (escape.c) so the preview keeps the original's output.
//

enum HTMLEscaping {
    /// `" & ' < >` as entities; `/` is left alone (hoedown's non-secure mode).
    static func html(_ text: some StringProtocol) -> String {
        guard text.utf8.contains(where: { $0 == 0x22 || $0 == 0x26 || $0 == 0x27 || $0 == 0x3C || $0 == 0x3E })
        else { return String(text) }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "&quot;"
            case "&": result += "&amp;"
            case "'": result += "&#39;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A URL for an `href` or `src`: characters safe in URLs as they are,
    /// `&` and `'` as entities, every other byte percent-encoded.
    static func href(_ url: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(url.utf8.count)
        for byte in url.utf8 {
            switch byte {
            case UInt8(ascii: "&"): result += "&amp;"
            case UInt8(ascii: "'"): result += "&#x27;"
            case _ where hrefSafe(byte): result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = Array("0123456789ABCDEF".utf8)
                result += "%"
                result.unicodeScalars.append(Unicode.Scalar(hex[Int(byte >> 4)]))
                result.unicodeScalars.append(Unicode.Scalar(hex[Int(byte & 0xF)]))
            }
        }
        return result
    }

    /// hoedown's HREF_SAFE table: printable ASCII except `" & ' < > [ \ ] ^ `` { | } ~` and space.
    private static func hrefSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x21, 0x23...0x25, 0x28...0x3B, 0x3D, 0x3F...0x5A, 0x5F, 0x61...0x7A: true
        default: false
        }
    }
}

//
//  ExtendedSyntax.swift
//  MacDownKit
//
//  Opt-in syntax cmark-gfm doesn't parse (`==highlight==`, `x^2`), found in
//  plain text the same way for the editor highlighting and the preview,
//  with hoedown's rules.
//

import Foundation

enum ExtendedSyntax {
    /// `==text==`: no space just inside either `==`, on one line.
    static let highlight = try! NSRegularExpression(pattern: #"==(?=[^\s=])(.*?\S)=="#)

    /// `^(text)`, or `^` and the non-space run after it (trailing punctuation
    /// included, as in hoedown). `[^` starts a footnote instead.
    static let superscript = try! NSRegularExpression(pattern: #"(?<!\[)\^(?:\(([^)\n]*)\)|(\S+))"#)
}

//
//  LiveDocumentTests.swift
//  MacDownKitTests
//

import Testing

/// Suites that drive real documents (editor and WKWebView) and change
/// `Preferences.shared`. Open documents react to every preference change, so
/// these suites must not run in parallel with each other.
@Suite(.serialized) enum LiveDocumentTests {}

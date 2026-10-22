//
//  DocumentWindowSizeTests.swift
//  MacDownKitTests
//

import AppKit
import Testing
@testable import MacDownKit

@MainActor @Suite struct DocumentWindowSizeTests {
    let screen = CGRect(x: 0, y: 30, width: 1440, height: 870)

    func makeDefaults() throws -> UserDefaults {
        let suite = "DocumentWindowSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func noSavedSizeUsesTheDefault() throws {
        let defaults = try makeDefaults()
        #expect(DocumentWindowSize.size(fitting: screen, in: defaults) == nil)
    }

    @Test func savesTheWindowFrameSize() throws {
        let defaults = try makeDefaults()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        DocumentWindowSize.save(from: window, in: defaults)
        #expect(DocumentWindowSize.size(fitting: screen, in: defaults)
                == window.frame.size)
    }

    @Test func sizeThatFitsIsUsed() throws {
        let defaults = try makeDefaults()
        defaults.set(NSStringFromSize(screen.size), forKey: DocumentWindowSize.key)
        #expect(DocumentWindowSize.size(fitting: screen, in: defaults) == screen.size)
    }

    @Test(arguments: [CGSize(width: 1441, height: 600), CGSize(width: 800, height: 871)])
    func sizeTooLargeForTheScreenUsesTheDefault(size: CGSize) throws {
        let defaults = try makeDefaults()
        defaults.set(NSStringFromSize(size), forKey: DocumentWindowSize.key)
        #expect(DocumentWindowSize.size(fitting: screen, in: defaults) == nil)
    }

    @Test func invalidSavedSizeIsIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set("garbage", forKey: DocumentWindowSize.key)
        #expect(DocumentWindowSize.size(fitting: screen, in: defaults) == nil)
    }
}

//
//  PlugIns.swift
//  MacDown
//
//  Ported from MPPlugIn.m and MPPlugInController.m. Plug-ins are bundles with
//  the ".plugin" extension in ~/Library/Application Support/MacDown/PlugIns.
//  The principal class may implement `name`, `plugInDidInitialize` and
//  `run:` (Objective-C selectors).
//

import AppKit
import Combine

public final class PlugIn: Identifiable {
    public let id: URL
    public let name: String
    private let content: NSObject

    init?(bundle: Bundle) {
        if !bundle.isLoaded {
            do { try bundle.loadAndReturnError() } catch { return nil }
        }
        guard let plugInClass = bundle.principalClass as? NSObject.Type else {
            return nil
        }
        content = plugInClass.init()
        id = bundle.bundleURL
        let nameSelector = NSSelectorFromString("name")
        if content.responds(to: nameSelector),
           let name = content.perform(nameSelector)?.takeUnretainedValue() as? String {
            self.name = name
        } else {
            name = bundle.bundleURL.deletingPathExtension().lastPathComponent
        }
    }

    func plugInDidInitialize() {
        let selector = NSSelectorFromString("plugInDidInitialize")
        if content.responds(to: selector) {
            content.perform(selector)
        }
    }

    @discardableResult
    public func run() -> Bool {
        let selector = NSSelectorFromString("run:")
        guard content.responds(to: selector) else {
            NSLog("Failed to run plugin %@", name)
            return false
        }
        content.perform(selector, with: self)
        return true
    }
}

@MainActor
public final class PlugInController: ObservableObject {
    public static let shared = PlugInController()

    @Published public private(set) var plugIns: [PlugIn] = []
    private var activationObserver: NSObjectProtocol?

    private init() {
        reload()
        plugIns.forEach { $0.plugInDidInitialize() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PlugInController.shared.reload() }
        }
    }

    public func reload() {
        let dir = MPPaths.dataDirectory(MPPaths.plugInsDirectoryName)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let existing = Dictionary(uniqueKeysWithValues: plugIns.map { ($0.id, $0) })
        plugIns = urls
            .filter { $0.pathExtension == MPPaths.plugInFileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                existing[url] ?? Bundle(url: url).flatMap(PlugIn.init(bundle:))
            }
    }
}

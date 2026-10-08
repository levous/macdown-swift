//
//  AppSupport.swift
//  MacDown
//
//  Application-level behavior ported from MPMainController.m.
//

import AppKit
import MacDownShared

@MainActor
public enum AppSupport {
    /// Copies a bundled file to a temporary location and opens it, so the
    /// bundled original is never modified.
    public static func openBundledFile(_ resource: String, _ ext: String) {
        guard let source = MPPaths.resourceBundle.url(forResource: resource,
                                                      withExtension: ext)
        else { return }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: target, display: true) {
            document, wasOpen, error in
            guard let document, !wasOpen, error == nil,
                  let frame = NSScreen.main?.visibleFrame
            else { return }
            for controller in document.windowControllers {
                controller.window?.setFrame(frame, display: true)
            }
        }
    }

    /// Copies built-in styles and themes into the data directory so users
    /// can modify them. Existing files are left alone.
    public static func copyFiles() {
        let manager = FileManager.default
        let root = MPPaths.dataRootDirectory
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        for key in [MPPaths.stylesDirectoryName, MPPaths.themesDirectoryName] {
            guard let dirSource = MPPaths.resourceBundle.url(forResource: key,
                                                             withExtension: nil)
            else { continue }
            let dirTarget = MPPaths.dataDirectory(key)
            // If the directory doesn't exist, just copy the whole thing.
            if !manager.fileExists(atPath: dirTarget.path) {
                try? manager.copyItem(at: dirSource, to: dirTarget)
                continue
            }
            // Copy each file that's not there.
            let contents = (try? manager.contentsOfDirectory(
                at: dirSource, includingPropertiesForKeys: nil)) ?? []
            for fileSource in contents {
                let fileTarget = dirTarget.appendingPathComponent(fileSource.lastPathComponent)
                if !manager.fileExists(atPath: fileTarget.path) {
                    try? manager.copyItem(at: fileSource, to: fileTarget)
                }
            }
        }
    }

    /// Opens files handed over by the `macdown` shell utility.
    public static func openPendingFiles() {
        let preferences = Preferences.shared
        guard let paths = preferences.filesToOpen, !paths.isEmpty else { return }
        preferences.filesToOpen = nil
        preferences.synchronize()

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if !((try? url.checkResourceIsReachable()) ?? false) {
                // Create an empty file for nonexistent paths.
                try? Data().write(to: url, options: .withoutOverwriting)
            }
            NSDocumentController.shared.openDocument(withContentsOf: url,
                                                     display: true) { _, _, _ in }
        }
    }

    /// Opens text piped into the `macdown` shell utility as a new document.
    public static func openPendingPipedContent() {
        let preferences = Preferences.shared
        guard let path = preferences.pipedContentFileToOpen else { return }
        preferences.pipedContentFileToOpen = nil
        preferences.synchronize()

        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        PendingDocumentContent.set(text)
        NSDocumentController.shared.newDocument(nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// Opens a file from a URL of the form
    /// `x-macdown://open?url=file:///path/to/a/file&line=123&column=45`.
    public static func handleURLScheme(_ urlString: String) {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open",
              let items = components.queryItems,
              let fileParam = items.first(where: { $0.name == "url" })?.value,
              let target = URL(string: fileParam)
        else { return }
        // Note: the line and column parameters are not supported (as in the
        // original application).
        NSDocumentController.shared.openDocument(withContentsOf: target, display: true) {
            document, wasOpen, error in
            guard let document, !wasOpen, error == nil,
                  let frame = NSScreen.main?.visibleFrame
            else { return }
            for controller in document.windowControllers {
                controller.window?.setFrame(frame, display: true)
            }
        }
    }
}

/// The application delegate.
@MainActor
public final class MacDownAppDelegate: NSObject, NSApplicationDelegate {
    private var freshInstallObserver: NSObjectProtocol?

    public override init() {
        super.init()
        freshInstallObserver = NotificationCenter.default.addObserver(
            forName: .didDetectFreshInstallation, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppSupport.openBundledFile("help", "md")
                AppSupport.openBundledFile("contribute", "md")
            }
        }
        _ = Preferences.shared
        AppSupport.copyFiles()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        _ = PlugInController.shared
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        else { return }
        AppSupport.handleURLScheme(string)
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        let preferences = Preferences.shared
        if !(preferences.filesToOpen ?? []).isEmpty
            || preferences.pipedContentFileToOpen != nil {
            return false
        }
        return !preferences.supressesUntitledDocumentOnLaunch
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        AppSupport.openPendingPipedContent()
        AppSupport.openPendingFiles()
    }
}

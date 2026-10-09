//
//  FileWatcher.swift
//  MacDown
//
//  Notices when a document's file changes on disk, written by any program
//  (editors, git, the shell), so DocumentController can load the new text or
//  ask about it. Not in the original MacDown, which relied on NSDocument.
//

import AppKit

@MainActor
final class FileWatcher {
    let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: Task<Void, Never>?

    /// Calls `onChange` shortly after the file at `url` changes; a burst of
    /// changes (a save written in parts, a git checkout) calls it once.
    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        watchIfNeeded()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    /// Starts watching again if the file was missing (deleted, or between
    /// the steps of an atomic save) when last looked for.
    func watchIfNeeded() {
        guard source == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func fileDidChange() {
        guard let source else { return }
        // Atomic saves (most editors, NSDocument) replace the file, and the
        // descriptor keeps following the old one; watch the path again.
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            source.cancel()
            self.source = nil
        }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.pendingChange = nil
            self.watchIfNeeded()
            self.onChange()
        }
    }
}

/// The question asked when the file changed on disk while the window has
/// unsaved changes.
@MainActor
enum FileChangeAlert {
    static func makeAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(name)” was changed by another application.")
        alert.informativeText = String(localized: "Do you want to keep your changes, or discard them and load the file from disk?")
        alert.addButton(withTitle: String(localized: "Keep My Changes"))
        let revert = alert.addButton(withTitle: String(localized: "Revert"))
        revert.hasDestructiveAction = true
        return alert
    }

    /// Asks in a sheet on `window`, and reports whether to load the file.
    static func ask(in window: NSWindow, name: String,
                    completion: @escaping (Bool) -> Void) {
        makeAlert(name: name).beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(response == .alertSecondButtonReturn)
            }
        }
    }
}

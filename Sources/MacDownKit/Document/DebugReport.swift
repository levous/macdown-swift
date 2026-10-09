//
//  DebugReport.swift
//  MacDown
//
//  Debug builds only: when MACDOWN_DEBUG_REPORT is set to a directory path,
//  each document writes a JSON report of its rendered preview plus snapshots
//  of the editor and preview after loading. Used to verify rendering from
//  the command line.
//

#if DEBUG
import AppKit
import WebKit

@MainActor
enum DebugReport {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["MACDOWN_DEBUG_REPORT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func write(for controller: DocumentController) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let name = controller.fileURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"
        let webView = controller.preview.webView

        let script = """
            (function () {
              var imgs = Array.prototype.map.call(document.images, function (i) {
                return { src: i.src, loaded: i.complete && i.naturalWidth > 0 };
              });
              var sheets = Array.prototype.map.call(document.styleSheets, function (s) {
                var rules = 0;
                try { rules = s.cssRules.length; } catch (e) { rules = -1; }
                return { href: s.href, rules: rules };
              });
              return JSON.stringify({
                title: document.title,
                location: String(location.href),
                prismLoaded: typeof Prism !== "undefined",
                prismTokens: document.querySelectorAll("code .token").length,
                tocLinks: document.querySelectorAll("ul.toc a").length,
                taskCheckboxes: document.querySelectorAll("li.task-list-item input").length,
                tables: document.querySelectorAll("table").length,
                images: imgs,
                styleSheets: sheets,
                bodyBackground: getComputedStyle(document.body).backgroundColor,
                headings: Array.prototype.map.call(
                  document.querySelectorAll("h1,h2,h3"), function (h) { return h.textContent; })
              });
            })();
            """
        var report: [String: Any] = [:]
        if let json = try? await webView.evaluateJavaScript(script) as? String,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            report["preview"] = object
        }
        let count = await controller.preview.fetchTextCount()
        report["textCount"] = ["words": count.words, "characters": count.characters,
                               "charactersNoSpaces": count.charactersNoSpaces]
        report["editorLength"] = (controller.editor.string as NSString).length
        report["editorFraction"] = controller.editorFraction
        report["editorBackground"] = controller.editorBackgroundColor.description
        report["editorFont"] = controller.editor.font?.fontName
        if let storage = controller.editor.textStorage, storage.length > 0 {
            // Distinct foreground colors in the editor (syntax highlighting).
            var colors = Set<String>()
            storage.enumerateAttribute(.foregroundColor,
                                       in: NSRange(location: 0, length: storage.length)) {
                value, _, _ in
                if let color = value as? NSColor { colors.insert(color.description) }
            }
            report["editorForegroundColors"] = colors.count
        }
        // Editing integration: a real keystroke must go through the
        // document's undo manager, mark the document edited, and be undoable.
        if ProcessInfo.processInfo.environment["MACDOWN_DEBUG_EDIT"] != nil,
           let window = controller.window {
            let editor = controller.editor
            let before = editor.string
            report["undoManagerIsEditors"] = editor.undoManager === controller.undoManager
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            // The typing path; then close the undo group as AppKit does at
            // the end of each event (groupsByEvent).
            editor.insertText("x", replacementRange: editor.selectedRange())
            if controller.undoManager.groupingLevel > 0 {
                let um = controller.undoManager
                um.endUndoGrouping()
            }
            try? await Task.sleep(for: .seconds(1))
            let afterTyping = editor.string
            report["typedOneCharacter"] = afterTyping == "x" + before
            report["lengthDelta"] = (afterTyping as NSString).length - (before as NSString).length
            report["beforePrefix"] = String(before.prefix(8))
            report["afterPrefix"] = String(afterTyping.prefix(8))
            report["documentFollowsEditor"] = controller.document.text == afterTyping
            report["canUndo"] = controller.undoManager.canUndo
            report["hasUnsavedChanges"] = controller.hasUnsavedChanges
            if let doc = NSDocumentController.shared.document(for: window) {
                report["documentEdited"] = doc.isDocumentEdited
            }
            controller.undoManager.undo()
            try? await Task.sleep(for: .milliseconds(500))
            report["restoredAfterUndo"] = editor.string == before
            report["documentRestored"] = controller.document.text == before
            if let doc = NSDocumentController.shared.document(for: window) {
                report["documentEditedAfterUndo"] = doc.isDocumentEdited
            }
        }
        report["localizedWordCount"] = controller.wordCountTitle(for: .words)
        report["localizedStrong"] = String(localized: "Strong")
        report["localizedAccessory"] = CodeBlockAccessoryType.languageName.title
        let previewMetrics = await controller.preview.fetchMetrics()
        report["previewScrollAnchors"] = previewMetrics.anchors.count
        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("\(name).json"))
        }

        // Snapshots.
        if let image = try? await webView.takeSnapshot(configuration: nil),
           let png = image.pngData {
            try? png.write(to: directory.appendingPathComponent("\(name)-preview.png"))
        }
        let editorView = controller.editorScrollView
        if editorView.bounds.width > 0,
           let rep = editorView.bitmapImageRepForCachingDisplay(in: editorView.bounds) {
            editorView.cacheDisplay(in: editorView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name)-editor.png"))
            }
        }
        if let window = controller.window, let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name)-window.png"))
            }
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif

//
//  MacDownScene.swift
//  MacDown
//
//  The application's scenes: Markdown document windows and Settings.
//

import SwiftUI

public struct MacDownScene: Scene {
    public init() {}

    public var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
        .commands { MacDownCommands() }
        // Windows open at the size the user last gave one (restored windows
        // keep their own frames).
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: DocumentWindowSize.size(
                fitting: context.defaultDisplay.visibleRect))
        }

        Settings {
            SettingsView()
        }
    }
}

//
//  MacDownApp.swift
//  MacDown
//

import MacDownKit
import SwiftUI

@main
struct MacDownApp: App {
    @NSApplicationDelegateAdaptor(MacDownAppDelegate.self) private var appDelegate

    var body: some Scene {
        MacDownScene()
    }
}

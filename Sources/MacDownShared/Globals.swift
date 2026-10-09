//
//  Globals.swift
//  MacDown
//
//  Constants shared between the application and the `macdown` shell utility.
//  The app and utility communicate through a shared user defaults suite, so
//  these values must agree between the two.
//

import Foundation

public enum MacDownGlobals {
    public static let applicationName = "MacDown"

    /// Bundle identifier of the application. This deliberately differs from
    /// the original Objective-C MacDown (`com.uranusjr.macdown`) so the two
    /// can be installed side by side.
    public static let applicationBundleIdentifier = "io.github.levous.macdown-swift"

    /// Suite used by the shell utility to hand files to the application.
    public static let applicationSuiteName = applicationBundleIdentifier

    public static let commandInstallationPath = "/usr/local/bin/macdown"
    public static let commandName = "macdown"

    public static let filesToOpenKey = "filesToOpenOnNextLaunch"
    public static let pipedContentFileToOpenKey =
        "pipedContentFileToOpenOnNextLaunch"

    public static let shortVersion = "1.1"
    public static let bundleVersion = "4"
}

//
//  main.swift
//  macdown-cmd
//
//  The `macdown` shell utility. Ported from macdown-cmd/main.m.
//
//  Arguments are treated as file names. They are converted to absolute paths
//  and stored in MacDown's user defaults suite, then MacDown is launched and
//  opens them. Text piped through stdin opens as a new document.
//

import AppKit
import Foundation
import MacDownShared

let suite = MacDownGlobals.applicationSuiteName

func printHelp() {
    print("""
        usage: \(MacDownGlobals.commandName) [file ...]

        Options:
          -v, --version  Print the version and exit.
          -h, --help     Print this help message and exit.
        """)
}

func printVersion() {
    print("\(MacDownGlobals.applicationName) \(MacDownGlobals.shortVersion) "
          + "(\(MacDownGlobals.bundleVersion))")
}

/// Data piped to the command through stdin, if any.
func pipedData() -> Data? {
    // Only read when stdin isn't a terminal and has data available.
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&fds, 1, 0) > 0, fds.revents & Int16(POLLIN) != 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return data.isEmpty ? nil : data
}

var files: [String] = []
var parsingOptions = true
for argument in CommandLine.arguments.dropFirst() {
    if parsingOptions && argument == "--" {
        parsingOptions = false
    } else if parsingOptions && (argument == "-h" || argument == "--help") {
        printHelp()
        exit(EXIT_SUCCESS)
    } else if parsingOptions && (argument == "-v" || argument == "--version") {
        printVersion()
        exit(EXIT_SUCCESS)
    } else if parsingOptions && argument.hasPrefix("-") && argument.count > 1 {
        FileHandle.standardError.write(Data("Unknown option \(argument)\n".utf8))
        printHelp()
        exit(EXIT_FAILURE)
    } else {
        files.append(argument)
    }
}

let defaults = UserDefaults(suiteName: suite)

// Store piped content in a temporary file to be read by MacDown on launch.
if let data = pipedData() {
    let name = "\(ProcessInfo.processInfo.globallyUniqueString)_pipedText.txt"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    if (try? data.write(to: url)) != nil {
        defaults?.set(url.path, forKey: MacDownGlobals.pipedContentFileToOpenKey)
    }
}

// Convert arguments to absolute paths (in order, without duplicates).
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
              isDirectory: true)
var paths: [String] = []
for file in files {
    let path = URL(fileURLWithPath: file, relativeTo: cwd).standardizedFileURL.path
    if !paths.contains(path) { paths.append(path) }
}
defaults?.set(paths, forKey: MacDownGlobals.filesToOpenKey)
defaults?.synchronize()

// Launch MacDown.
guard let appURL = NSWorkspace.shared.urlForApplication(
    withBundleIdentifier: MacDownGlobals.applicationBundleIdentifier)
else {
    FileHandle.standardError.write(Data("Could not find MacDown.app\n".utf8))
    exit(EXIT_FAILURE)
}

let semaphore = DispatchSemaphore(value: 0)
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
    if let error {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    }
    semaphore.signal()
}
semaphore.wait()
exit(EXIT_SUCCESS)

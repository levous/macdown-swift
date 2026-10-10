// Screenshots the frontmost on-screen window of an app, for checking the
// running app (see .claude/commands/goal.md).
//
//     swift Tools/capture-window.swift <app name> <output.png> [title substring]
//
// Lists the app's windows if none matches. Needs Screen Recording permission
// for the app running it (the terminal or editor).

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: capture-window <app> <out.png> [title]\n".utf8))
    exit(2)
}
let owner = args[1], output = args[2]
let title = args.count > 3 ? args[3] : nil

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
let windows = info.filter {
    ($0[kCGWindowOwnerName as String] as? String) == owner
        && ($0[kCGWindowLayer as String] as? Int) == 0
}
let match = windows.first { window in
    guard let title else { return true }
    return (window[kCGWindowName as String] as? String ?? "").contains(title)
}
guard let match, let id = match[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("no matching window; \(owner) has: \(windows.map { $0[kCGWindowName as String] as? String ?? "?" })\n".utf8))
    exit(1)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = ["-x", "-o", "-l", String(id), output]
try process.run()
process.waitUntilExit()
print("captured window \(id) \"\(match[kCGWindowName as String] as? String ?? "")\" → \(output)")
exit(process.terminationStatus)

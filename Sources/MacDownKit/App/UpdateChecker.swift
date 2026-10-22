//
//  UpdateChecker.swift
//  MacDown
//
//  Tells the user when a newer release is on GitHub. Nothing is downloaded
//  or installed (the original's Sparkle updater wasn't ported): the notice
//  links to the release, or for a Homebrew install shows the brew command,
//  so brew stays in charge of the app. Automatic checks run at most once a
//  day and announce each version once; MacDown ▸ Check for Updates… always
//  answers. The setting and its state use Sparkle's user defaults keys.
//

import AppKit
import MacDownShared

@MainActor
public final class UpdateChecker {
    public static let shared = UpdateChecker()

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/levous/macdown-swift/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Homebrew casks MacDown is installed from, by their Caskroom folder
    /// name, and the command that upgrades each: the levous/tap cask, and
    /// the name prepared for Homebrew's own cask repository.
    static let casks: [(folder: String, command: String)] = [
        ("macdown-swift", "brew upgrade --cask levous/tap/macdown-swift"),
        ("levous-macdown", "brew upgrade --cask levous-macdown"),
    ]

    struct Release: Equatable, Sendable {
        var version: String
        var pageURL: URL
    }

    /// What a check found, for the notice.
    enum Outcome: Equatable {
        /// A newer release; `brewCommand` upgrades a Homebrew install.
        case available(Release, current: String, brewCommand: String?)
        case upToDate(current: String)
        case failed
    }

    var defaults: UserDefaults
    var currentVersion: String
    var now: () -> Date = Date.init
    /// The latest release's JSON from GitHub.
    var fetch: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    /// The command that upgrades MacDown's Homebrew cask, or nil if it
    /// wasn't installed with Homebrew.
    var homebrewUpgradeCommand: () -> String? = {
        let caskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        return UpdateChecker.casks.first { cask in
            caskrooms.contains { FileManager.default.fileExists(atPath: "\($0)/\(cask.folder)") }
        }?.command
    }
    /// Shows the notice; `userInitiated` checks also report no update or an error.
    var present: (Outcome) -> Void = { UpdateChecker.showAlert(for: $0) }

    init(defaults: UserDefaults = .standard, currentVersion: String = MacDownGlobals.shortVersion) {
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    // MARK: - Checking

    /// On launch: checks if the setting is on and a day has passed.
    public func checkAutomaticallyIfDue() {
        guard isAutomaticCheckDue else { return }
        Task { await check(userInitiated: false) }
    }

    var isAutomaticCheckDue: Bool {
        guard defaults.bool(forKey: .SUEnableAutomaticChecks) else { return false }
        guard let last = defaults.object(forKey: .SULastCheckTime) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.checkInterval
    }

    /// MacDown ▸ Check for Updates…
    public func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        let release = try? Self.release(from: await fetch(Self.latestReleaseURL))
        defaults.set(now(), forKey: .SULastCheckTime)
        guard let release else {
            if userInitiated { present(.failed) }
            return
        }
        guard Self.isNewer(release.version, than: currentVersion) else {
            if userInitiated { present(.upToDate(current: currentVersion)) }
            return
        }
        // Automatic checks announce each version once.
        if !userInitiated, defaults.string(forKey: .SUSkippedVersion) == release.version { return }
        defaults.set(release.version, forKey: .SUSkippedVersion)
        present(.available(release, current: currentVersion, brewCommand: homebrewUpgradeCommand()))
    }

    // MARK: - Versions

    /// The release in GitHub's "latest release" JSON; nil for drafts and
    /// prereleases (which that endpoint shouldn't return anyway).
    static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !numbers(version).isEmpty else { return nil }
        return Release(version: version, pageURL: page)
    }

    /// Whether `candidate` is a later version than `current`, comparing
    /// dotted numbers (1.2.10 is after 1.2.9; 1.3 equals 1.3.0).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    // MARK: - Notice

    static func showAlert(for outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .available(let release, let current, let brewCommand):
            alert.messageText = String(localized: "MacDown \(release.version) is available")
            if let brewCommand {
                alert.informativeText = String(localized: "You have \(current). MacDown was installed with Homebrew; update it in Terminal with:\n\n\(brewCommand)")
                alert.addButton(withTitle: String(localized: "Copy Command"))
            } else {
                alert.informativeText = String(localized: "You have \(current).")
                alert.addButton(withTitle: String(localized: "Download"))
            }
            alert.addButton(withTitle: String(localized: "Not Now"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let brewCommand {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(brewCommand, forType: .string)
            } else {
                NSWorkspace.shared.open(release.pageURL)
            }
        case .upToDate(let current):
            alert.messageText = String(localized: "You’re up to date")
            alert.informativeText = String(localized: "MacDown \(current) is the latest version.")
            alert.runModal()
        case .failed:
            alert.messageText = String(localized: "Couldn’t check for updates")
            alert.informativeText = String(localized: "GitHub couldn’t be reached. Check your internet connection and try again.")
            alert.runModal()
        }
    }
}

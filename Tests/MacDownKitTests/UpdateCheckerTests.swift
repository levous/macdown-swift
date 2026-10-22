//
//  UpdateCheckerTests.swift
//  MacDownKitTests
//
//  Checking GitHub for a newer release, with the network and the alert
//  replaced.
//

import Foundation
import Testing
@testable import MacDownKit

@MainActor @Suite struct UpdateCheckerTests {
    static func releaseJSON(_ tag: String, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/levous/macdown-swift/releases/tag/\#(tag)", "draft": false, "prerelease": \#(prerelease)}"#.utf8)
    }

    /// A checker on a private defaults suite, with GitHub answering `latest`
    /// (nil: unreachable), and the notices it shows.
    @MainActor final class Harness {
        let suite = "MacDownTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let checker: UpdateChecker
        var shown: [UpdateChecker.Outcome] = []

        init(current: String = "1.2.3", latest: Data?, brewCommand: String? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            checker = UpdateChecker(defaults: defaults, currentVersion: current)
            checker.fetch = { _ in
                guard let latest else { throw URLError(.notConnectedToInternet) }
                return latest
            }
            checker.homebrewUpgradeCommand = { brewCommand }
            checker.present = { [unowned self] in shown.append($0) }
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    @Test func versionOrder() {
        #expect(UpdateChecker.isNewer("1.2.4", than: "1.2.3"))
        #expect(UpdateChecker.isNewer("1.2.10", than: "1.2.9"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        #expect(UpdateChecker.isNewer("1.3", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
        #expect(!UpdateChecker.isNewer("1.3", than: "1.3.0"))
        #expect(!UpdateChecker.isNewer("1.2.2", than: "1.2.3"))
        #expect(!UpdateChecker.isNewer("1.2.4-beta", than: "1.2.3"))
    }

    @Test func releasesFromGitHub() {
        let release = UpdateChecker.release(from: Self.releaseJSON("v1.2.4"))
        #expect(release == .init(version: "1.2.4",
                                 pageURL: URL(string: "https://github.com/levous/macdown-swift/releases/tag/v1.2.4")!))
        #expect(UpdateChecker.release(from: Self.releaseJSON("1.3"))?.version == "1.3")
        #expect(UpdateChecker.release(from: Self.releaseJSON("v1.3", prerelease: true)) == nil)
        #expect(UpdateChecker.release(from: Self.releaseJSON("nightly")) == nil)
        #expect(UpdateChecker.release(from: Data("not json".utf8)) == nil)
    }

    /// An automatic check announces a new version once; asking always answers.
    @Test func newReleaseIsAnnouncedOnce() async {
        let harness = Harness(latest: Self.releaseJSON("v1.2.4"))
        let release = UpdateChecker.release(from: Self.releaseJSON("v1.2.4"))!
        await harness.checker.check(userInitiated: false)
        await harness.checker.check(userInitiated: false)
        #expect(harness.shown == [.available(release, current: "1.2.3", brewCommand: nil)])
        await harness.checker.check(userInitiated: true)
        #expect(harness.shown == [.available(release, current: "1.2.3", brewCommand: nil), .available(release, current: "1.2.3", brewCommand: nil)])
    }

    @Test func homebrewInstallsGetTheBrewCommand() async {
        let command = "brew upgrade --cask levous/tap/macdown-swift"
        let harness = Harness(latest: Self.releaseJSON("v1.2.4"), brewCommand: command)
        await harness.checker.check(userInitiated: false)
        #expect(harness.shown == [.available(UpdateChecker.release(from: Self.releaseJSON("v1.2.4"))!,
                                             current: "1.2.3", brewCommand: command)])
        // The tap's cask, which the release script publishes, comes first.
        #expect(UpdateChecker.casks.first?.folder == "macdown-swift")
    }

    /// Automatic checks stay quiet unless there's something new.
    @Test func quietUnlessAskedOrNew() async {
        let current = Harness(latest: Self.releaseJSON("v1.2.3"))
        await current.checker.check(userInitiated: false)
        #expect(current.shown.isEmpty)
        await current.checker.check(userInitiated: true)
        #expect(current.shown == [.upToDate(current: "1.2.3")])

        let offline = Harness(latest: nil)
        await offline.checker.check(userInitiated: false)
        #expect(offline.shown.isEmpty)
        await offline.checker.check(userInitiated: true)
        #expect(offline.shown == [.failed])
    }

    /// At most once a day, and only with the setting on.
    @Test func automaticChecksAreDailyAndOptional() async {
        let harness = Harness(latest: Self.releaseJSON("v1.2.3"))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        harness.checker.now = { clock }
        harness.defaults.set(true, forKey: PreferenceSettingKey.SUEnableAutomaticChecks.rawValue)
        #expect(harness.checker.isAutomaticCheckDue)
        await harness.checker.check(userInitiated: false)
        clock += 60 * 60
        #expect(!harness.checker.isAutomaticCheckDue)
        clock += 23 * 60 * 60
        #expect(harness.checker.isAutomaticCheckDue)
        harness.defaults.set(false, forKey: PreferenceSettingKey.SUEnableAutomaticChecks.rawValue)
        #expect(!harness.checker.isAutomaticCheckDue)
    }

    /// On by default, for existing installs too, and keeps the user's choice.
    @Test func settingDefaultsOn() throws {
        for existing in [false, true] {
            let suite = "MacDownTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if existing { defaults.set("1", forKey: .firstVersionInstalled) }
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.automaticallyChecksForUpdates, "existing install: \(existing)")
            preferences.automaticallyChecksForUpdates = false
            #expect(!Preferences(defaults: defaults).automaticallyChecksForUpdates)
        }
        // Sparkle's key, so a choice made in the original carries over.
        #expect(PreferenceSettingKey.SUEnableAutomaticChecks.rawValue == "SUEnableAutomaticChecks")
    }
}

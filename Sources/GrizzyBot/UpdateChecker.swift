import AppKit
import Foundation

/// Asks GitHub for the latest published release and compares it with the running version.
/// Nothing is downloaded or installed: the person is sent to the release page.
enum UpdateChecker {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Foscoe63/GrizzyBot/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Foscoe63/GrizzyBot/releases")!

    enum Outcome: Sendable {
        case upToDate(current: String)
        case available(current: String, latest: String, url: URL)
        case failed(String)
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    @MainActor private static var didAutoCheck = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func check() async -> Outcome {
        let current = currentVersion
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GrizzyBot", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .upToDate(current: current) // no releases published yet
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("GitHub returned an unexpected response.")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            return isNewer(latest, than: current)
                ? .available(current: current, latest: latest, url: release.html_url)
                : .upToDate(current: current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Dotted numeric comparison ("0.18.0" < "0.19"); missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map(String.init)?
                .split(separator: ".").map { Int($0) ?? 0 } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Runs a check and tells the person the result. `silent` suppresses "up to date" and errors
    /// (used for the automatic check at launch).
    @MainActor
    static func run(silent: Bool) async {
        if silent {
            guard !didAutoCheck else { return }
            didAutoCheck = true
        }
        let outcome = await check()
        let alert = NSAlert()
        switch outcome {
        case .available(let current, let latest, let url):
            alert.messageText = "GrizzyBot \(latest) is available"
            alert.informativeText = "You have \(current). Open the release page to download the update."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        case .upToDate(let current):
            guard !silent else { return }
            alert.messageText = "GrizzyBot is up to date"
            alert.informativeText = "You have the latest version (\(current))."
            alert.runModal()
        case .failed(let message):
            guard !silent else { return }
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
        }
    }
}

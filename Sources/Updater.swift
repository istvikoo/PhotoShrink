import SwiftUI
import AppKit

// Self-updater that uses GitHub Releases.
// A release must have a tag like "v1.2.0" and a zip asset containing PhotoShrink.app
// (release.sh makes exactly that).

enum UpdateConfig {
    static let repo = "istvikoo/PhotoShrink"

    /// For local testing you can point the updater elsewhere:
    /// PHOTOSHRINK_UPDATE_URL=http://localhost:8000/latest.json
    static var latestReleaseURL: URL {
        if let s = ProcessInfo.processInfo.environment["PHOTOSHRINK_UPDATE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL
    let body: String?
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var zipAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
}

/// "1.10.0" > "1.9.2"
func isVersion(_ a: String, newerThan b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

enum UpdateError: LocalizedError {
    case noAsset, badArchive, wrongApp, translocated, cannotReplace(String)
    var errorDescription: String? {
        switch self {
        case .noAsset: return tr("У релізі немає zip-файлу з програмою", "The release has no app zip file")
        case .badArchive: return tr("Не вдалося розпакувати оновлення", "Could not unpack the update")
        case .wrongApp: return tr("Завантажений файл не пройшов перевірку", "The downloaded app failed verification")
        case .translocated:
            return tr("Перемістіть PhotoShrink у папку «Програми» і запустіть знову — тоді оновлення встановиться.",
                      "Move PhotoShrink to the Applications folder and open it again, then the update can be installed.")
        case .cannotReplace(let m): return tr("Не вдалося замінити програму: ", "Could not replace the app: ") + m
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking
        case available(GitHubReleaseInfo)
        case installing
    }
    struct GitHubReleaseInfo: Equatable {
        let version: String
        let page: URL
        let zip: URL?
    }

    @Published var state: State = .idle

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var autoCheck: Bool {
        UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    /// Called on launch: quiet check, at most once every 6 hours.
    func checkOnLaunch() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        if state == .checking || state == .installing { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: UpdateConfig.latestReleaseURL)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                    // No releases published yet.
                    state = .idle
                    if userInitiated { alert(tr("Оновлень немає", "No updates"), tr("Ще немає опублікованих версій.", "No versions have been published yet.")) }
                    return
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

                if isVersion(release.version, newerThan: Self.currentVersion) {
                    state = .available(GitHubReleaseInfo(version: release.version, page: release.html_url,
                                                         zip: release.zipAsset?.browser_download_url))
                } else {
                    state = .idle
                    if userInitiated {
                        alert(tr("У вас остання версія", "You're up to date"),
                              tr("PhotoShrink \(Self.currentVersion) — найновіша версія.",
                                 "PhotoShrink \(Self.currentVersion) is the latest version."))
                    }
                }
            } catch {
                state = .idle
                if userInitiated {
                    alert(tr("Не вдалося перевірити оновлення", "Could not check for updates"), error.localizedDescription)
                }
            }
        }
    }

    func install(_ info: GitHubReleaseInfo) {
        guard let zipURL = info.zip else { fail(UpdateError.noAsset, page: info.page); return }
        state = .installing
        Task {
            do {
                let (tmpZip, _) = try await URLSession.shared.download(from: zipURL)
                let newApp = try await Task.detached { try Self.unpackAndVerify(tmpZip, expectedVersion: info.version) }.value
                try Self.replaceRunningApp(with: newApp)
                Self.relaunch()
            } catch {
                fail(error, page: info.page)
            }
        }
    }

    private func fail(_ error: Error, page: URL) {
        state = .idle
        let a = NSAlert()
        a.messageText = tr("Оновлення не встановилося", "Update failed")
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: tr("Відкрити сторінку релізу", "Open release page"))
        a.addButton(withTitle: tr("Закрити", "Close"))
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Install steps (off the main thread)

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Unzips the download and checks it is really PhotoShrink of the expected version.
    nonisolated private static func unpackAndVerify(_ zip: URL, expectedVersion: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoShrinkUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else { throw UpdateError.badArchive }

        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }),
              let newBundle = Bundle(url: app),
              newBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (newBundle.infoDictionary?["CFBundleShortVersionString"] as? String) == expectedVersion
        else { throw UpdateError.wrongApp }

        // Signature must be intact (catches corrupted or tampered bundles).
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw UpdateError.wrongApp }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private static func replaceRunningApp(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        // Gatekeeper runs quarantined apps from a read-only random location.
        if current.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp, backupItemName: nil, options: [])
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
    }

    private static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Banner shown at the top of the window when a new version exists.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        switch updater.state {
        case .available(let info):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text(tr("Доступна нова версія \(info.version)", "New version \(info.version) is available"))
                Spacer()
                Button(tr("Що нового", "What's new")) { NSWorkspace.shared.open(info.page) }
                    .buttonStyle(.link)
                Button(tr("Оновити", "Update")) { updater.install(info) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tr("Завантаження й встановлення оновлення…", "Downloading and installing the update…"))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
        default:
            EmptyView()
        }
    }
}

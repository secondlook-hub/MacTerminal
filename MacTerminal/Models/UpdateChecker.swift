import Foundation
import SwiftUI

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

@MainActor
class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var upToDate = false
    @Published var latestVersion = ""
    @Published var downloadURL: URL?
    @Published var releaseURL: URL?

    private let repo = "secondlook-hub/MacTerminal"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func checkForUpdates(manual: Bool = false) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            if isNewer(remoteVersion, than: currentVersion) {
                latestVersion = remoteVersion
                releaseURL = URL(string: release.htmlUrl)

                if let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                    downloadURL = URL(string: dmgAsset.browserDownloadUrl)
                }

                updateAvailable = true
            } else if manual {
                upToDate = true
            }
        } catch {
            print("Update check failed: \(error.localizedDescription)")
        }
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(remoteParts.count, currentParts.count)
        for i in 0..<maxCount {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
}

import AppKit
import BezlCore
import Foundation
import Observation

/// Checks GitHub Releases for a newer version. Never downloads or installs anything:
/// it only offers to open the release page.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case noReleases
        case failed(String)
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/shivshekhar12/bezl/releases/latest")!

    private(set) var status: Status = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": "Bezl"]
        return URLSession(configuration: config)
    }()

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
    }

    func check() async {
        status = .checking
        do {
            let (data, response) = try await session.data(from: Self.releasesAPI)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { status = .noReleases; return }
            guard code == 200 else { status = .failed("GitHub returned \(code)"); return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = SemanticVersion(release.tag_name),
                  let current = SemanticVersion(currentVersion) else {
                status = .failed("Unrecognized version \(release.tag_name)")
                return
            }
            status = current < latest ? .available(version: latest.description, url: release.html_url) : .upToDate
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    var statusText: String {
        switch status {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Bezl \(currentVersion) is up to date."
        case let .available(version, _): "Bezl \(version) is available."
        case .noReleases: "No releases published yet."
        case let .failed(message): "Couldn't check: \(message)"
        }
    }
}

import BezlCore
import Foundation
import Observation

/// Fetches lyrics from LRCLIB (https://lrclib.net), a free, open, community lyrics database.
/// Only used after the user opts in, because it sends the track title, artist and duration.
@MainActor
@Observable
final class LyricsService {
    enum State: Equatable {
        case idle
        case loading
        case synced(SyncedLyrics)
        case plain(String)
        case instrumental
        case notFound
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 12
        // LRCLIB asks clients to identify themselves; a generic product name is enough.
        config.httpAdditionalHeaders = ["User-Agent": "Bezl (open-source macOS app)"]
        return URLSession(configuration: config)
    }()

    func load(for track: Track?) {
        guard let track else {
            task?.cancel()
            loadedKey = nil
            state = .idle
            return
        }
        let key = track.cacheKey
        guard key != loadedKey else { return }
        loadedKey = key
        task?.cancel()
        if let cached = cache[key] { state = cached; return }
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            let result = await self.fetch(title: track.title, artist: track.artist, album: track.album,
                                          duration: track.duration)
            guard !Task.isCancelled, self.loadedKey == key else { return }
            if case .failed = result {} else { self.cache[key] = result }
            self.state = result
        }
    }

    func reset() {
        task?.cancel()
        loadedKey = nil
        state = .idle
    }

    private struct Record: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let duration: Double?
    }

    private func fetch(title: String, artist: String, album: String, duration: Double) async -> State {
        // 1. Exact match by signature.
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
        ]
        if duration > 0 { get.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        do {
            let (data, response) = try await session.data(from: get.url!)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let record = try? JSONDecoder().decode(Record.self, from: data) {
                return state(from: record)
            }
            // 2. Fuzzy search fallback; prefer synced results with a close duration.
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [URLQueryItem(name: "track_name", value: title),
                                 URLQueryItem(name: "artist_name", value: artist)]
            let (sdata, sresponse) = try await session.data(from: search.url!)
            guard (sresponse as? HTTPURLResponse)?.statusCode == 200,
                  let records = try? JSONDecoder().decode([Record].self, from: sdata), !records.isEmpty else {
                return .notFound
            }
            let ranked = records.sorted { a, b in
                let aSynced = a.syncedLyrics?.isEmpty == false, bSynced = b.syncedLyrics?.isEmpty == false
                if aSynced != bSynced { return aSynced }
                let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
                return da < db
            }
            return state(from: ranked[0])
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func state(from record: Record) -> State {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, let parsed = SyncedLyrics.parse(synced) { return .synced(parsed) }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return .notFound
    }
}

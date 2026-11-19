import Foundation

/// Time-synced lyrics parsed from the LRC format ("[mm:ss.xx] line").
public struct SyncedLyrics: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var time: Double      // seconds
        public var text: String

        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    public var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines.sorted { $0.time < $1.time }
    }

    /// Parses LRC text. Supports multiple timestamps per line ("[00:12.00][01:30.50] chorus"),
    /// 1–3 fractional digits, and skips metadata tags like "[ar: Artist]" or "[offset:+200]".
    /// Applies the `[offset:±ms]` tag if present (positive = lyrics appear earlier).
    public static func parse(_ text: String) -> SyncedLyrics? {
        var lines: [Line] = []
        var offset = 0.0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let lyric = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(Line(time: t, text: lyric)) }
        }
        guard !lines.isEmpty else { return nil }
        if offset != 0 {
            lines = lines.map { Line(time: max(0, $0.time - offset), text: $0.text) }
        }
        return SyncedLyrics(lines: lines)
    }

    /// "mm:ss", "mm:ss.x", "mm:ss.xx", "mm:ss.xxx" (also ":" before the fraction).
    static func parseTimestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsPart = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secondsPart), seconds >= 0, seconds < 60,
              secondsPart.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// Index of the line being sung at `time` (the last line that has started), or nil before the first.
    public func lineIndex(at time: Double) -> Int? {
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

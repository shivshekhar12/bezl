import Foundation

/// A loose semantic version ("v1.2.3", "1.2", "1.2.3-beta") for update checks.
/// Pre-release suffixes sort before the release with the same numbers.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: String?

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let mainAndPre = s.split(separator: "-", maxSplits: 1)
        guard let main = mainAndPre.first else { return nil }
        let nums = main.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.count <= 3, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = nums[0]!
        minor = nums.count > 1 ? nums[1]! : 0
        patch = nums.count > 2 ? nums[2]! : 0
        prerelease = mainAndPre.count > 1 ? String(mainAndPre[1]) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool {
        !(a < b) && !(b < a)
    }
}

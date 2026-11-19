import AppKit
import Foundation

/// Result of an AppleScript call, reduced to Sendable values.
enum ScriptResult: Sendable {
    case text(String)
    case data(Data)
    case failure(code: Int, message: String)

    /// errAEEventNotPermitted: the user denied Automation access.
    var isPermissionDenied: Bool {
        if case let .failure(code, _) = self { return code == -1743 }
        return false
    }
}

/// Runs AppleScript on one serial background queue (NSAppleScript blocks and is not thread-safe).
enum ScriptRunner {
    private static let queue = DispatchQueue(label: "bezl.applescript", qos: .utility)

    static func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: execute(source))
            }
        }
    }

    private static func execute(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else {
            return .failure(code: -1, message: "Could not compile script")
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            return .failure(code: code, message: message)
        }
        if let string = descriptor.stringValue {
            return .text(string)
        }
        return .data(descriptor.data)
    }
}

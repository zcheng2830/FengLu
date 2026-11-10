import Foundation
import OSLog

enum DebugLog {
    private static let logger = Logger(subsystem: "com.fenglu.player", category: "Debug")

    /// Log messages carry file paths, track titles and playlist lines, so they
    /// are only emitted in debug builds, or when explicitly requested with
    /// `FENGLU_DEBUG_LOG=1` or `defaults write com.fenglu.player FengluDebugLog -bool YES`.
    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        if let value = ProcessInfo.processInfo.environment["FENGLU_DEBUG_LOG"]?.lowercased() {
            return ["1", "true", "yes"].contains(value)
        }

        return UserDefaults.standard.bool(forKey: "FengluDebugLog")
        #endif
    }()

    static func log(_ message: @autoclosure () -> String) {
        // Disabled logging must not even build the message.
        guard isEnabled else {
            return
        }

        let value = message()
        logger.notice("\(value, privacy: .public)")

        if let data = "[Fenglu] \(value)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

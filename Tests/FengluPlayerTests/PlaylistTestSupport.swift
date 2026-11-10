import Foundation
@testable import FengluPlayer

enum PlaylistTestSupport {
    static let baseURL = URL(fileURLWithPath: "/music/album", isDirectory: true)

    /// An environment where exactly the given paths exist, each with the given duration.
    static func environment(_ durations: [String: TimeInterval]) -> PlaylistParsingEnvironment {
        PlaylistParsingEnvironment(
            fileExists: { durations[$0.path] != nil },
            duration: { durations[$0.path] }
        )
    }

    static func environment(existing paths: [String]) -> PlaylistParsingEnvironment {
        environment(Dictionary(uniqueKeysWithValues: paths.map { ($0, 600) }))
    }

    static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        )
    }
}

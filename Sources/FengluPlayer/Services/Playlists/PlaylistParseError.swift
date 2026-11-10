import Foundation

enum PlaylistParseError: LocalizedError, Equatable {
    case invalidXSPF(line: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidXSPF(let line):
            if let line {
                "The XSPF playlist is not valid XML (line \(line))"
            } else {
                "The XSPF playlist could not be parsed"
            }
        }
    }
}

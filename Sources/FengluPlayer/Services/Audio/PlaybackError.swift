import Foundation

enum PlaybackError: LocalizedError {
    case nativeDecoderUnavailable(String)
    case ffmpegDecoderFailed(String)

    var errorDescription: String? {
        switch self {
        case .nativeDecoderUnavailable(let name):
            "macOS native decoding is not available for \(name)"
        case .ffmpegDecoderFailed(let message):
            message
        }
    }
}

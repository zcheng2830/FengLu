import Foundation

enum TimeFormatter {
    /// 100,000 hours; anything longer is a corrupt value, not a duration.
    private static let maximumDisplayableSeconds: TimeInterval = 360_000_000

    static func duration(_ seconds: TimeInterval) -> String {
        // `Int(_:)` traps on values outside its range, so bound the input first.
        guard seconds.isFinite, seconds >= 0, seconds < maximumDisplayableSeconds else {
            return "--:--"
        }

        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}

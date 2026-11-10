import Foundation
import Testing
@testable import FengluPlayer

struct TimeFormatterTests {
    @Test(arguments: [
        (0.0, "00:00"),
        (59.4, "00:59"),
        (59.6, "01:00"),
        (3599.0, "59:59"),
        (3600.0, "1:00:00"),
        (86_399.0, "23:59:59"),
        (-1.0, "--:--"),
        (Double.nan, "--:--"),
        (Double.infinity, "--:--"),
        (1e30, "--:--"),
        (Double.greatestFiniteMagnitude, "--:--")
    ])
    func formatsDurations(seconds: Double, expected: String) {
        #expect(TimeFormatter.duration(seconds) == expected)
    }
}

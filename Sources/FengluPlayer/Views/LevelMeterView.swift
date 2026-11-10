import SwiftUI

struct LevelMeterView: View {
    var isActive: Bool

    private let bars = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(for: index))
                        .frame(width: 5, height: barHeight(index: index, date: timeline.date))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        guard isActive else {
            return CGFloat(8 + (index % 3) * 3)
        }

        let phase = date.timeIntervalSinceReferenceDate * 4
        let wave = sin(phase + Double(index) * 0.65)
        let secondary = cos((phase * 0.7) + Double(index) * 0.35)
        return CGFloat(12 + ((wave + secondary + 2) / 4) * 34)
    }

    private func barColor(for index: Int) -> Color {
        switch index {
        case 0..<12:
            .green
        case 12..<18:
            .yellow
        default:
            .red
        }
    }
}

import SwiftUI

struct NowPlayingView: View {
    var track: AudioTrack?
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 5) {
                Text(track?.title ?? "No Track Loaded")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    StatusPill(systemImage: playback.route.systemImage, text: playback.route.title)
                    StatusPill(systemImage: "doc", text: track?.formatLabel ?? "--")
                    StatusPill(systemImage: "clock", text: playback.state.title)
                }
            }

            Spacer(minLength: 16)

            LevelMeterView(isActive: playback.state.isPlaying)
                .frame(width: 180, height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        guard let track else {
            return "Ready"
        }

        return track.subtitle.nonEmpty ?? track.fileName
    }
}

private struct StatusPill: View {
    var systemImage: String
    var text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }
}

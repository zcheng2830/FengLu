import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController

    private var liveFFmpegTrackID: AudioTrack.ID? {
        playback.route == .ffmpeg ? playback.currentTrackID : nil
    }

    private var filterSelection: Binding<LibraryFilter?> {
        Binding {
            store.filter
        } set: { newValue in
            if let newValue {
                store.filter = newValue
            }
        }
    }

    var body: some View {
        List(selection: filterSelection) {
            Section("Library") {
                ForEach(LibraryFilter.allCases) { filter in
                    Label {
                        HStack {
                            Text(filter.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(store.count(for: filter, liveFFmpegTrackID: liveFFmpegTrackID))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: filter.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .tag(filter)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

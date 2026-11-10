import Foundation
import SwiftUI

struct TransportBarView: View {
    var track: AudioTrack?
    @ObservedObject var playback: PlaybackController
    @ObservedObject var playbackClock: PlaybackClock
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onToggle: () -> Void
    var onStop: () -> Void

    @State private var seekEditingContext: SeekEditingContext?
    /// Position under the thumb while it is being dragged. The seek itself
    /// happens once, when the drag ends.
    @State private var draggedElapsed: TimeInterval?

    var body: some View {
        let duration = playback.displayDuration(for: track)
        let playbackElapsed = playback.displayElapsed(for: track)
        let sliderMaximum = max(duration ?? playbackElapsed, playbackElapsed, 1)
        let elapsed = draggedElapsed.map { min($0, sliderMaximum) } ?? playbackElapsed

        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(TimeFormatter.duration(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)

                Slider(
                    value: Binding {
                        min(elapsed, sliderMaximum)
                    } set: { newValue in
                        guard let track else {
                            return
                        }

                        if let context = seekEditingContext {
                            // A drag is in flight. If the track changed under it the
                            // drag stays invalid until release: its updates are
                            // discarded rather than applied to the new track.
                            if context.trackID == track.id {
                                draggedElapsed = newValue
                            }
                        } else {
                            // Not a drag (keyboard or accessibility adjustment):
                            // there is no end-of-edit event to wait for.
                            commitSeek(toElapsed: newValue, context: SeekEditingContext(track: track))
                        }
                    },
                    in: 0...sliderMaximum,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            seekEditingContext = track.map(SeekEditingContext.init(track:))
                            return
                        }

                        if let context = seekEditingContext, let draggedElapsed, context.trackID == track?.id {
                            commitSeek(toElapsed: draggedElapsed, context: context)
                        }
                        seekEditingContext = nil
                        draggedElapsed = nil
                    }
                )
                .onChange(of: track?.id) { _, _ in
                    // The track changed under an in-flight drag. Forget the dragged
                    // position but keep the context (which names the old track), so
                    // the rest of this drag is recognised as stale and ignored
                    // instead of being treated as a keyboard adjustment.
                    draggedElapsed = nil
                }

                Text(duration.map(TimeFormatter.duration) ?? "--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
            }

            HStack(spacing: 12) {
                IconButton(systemName: "backward.end.fill", help: "Previous (⌘←)", action: onPrevious)

                IconButton(
                    systemName: playback.state.isPlaying ? "pause.fill" : "play.fill",
                    help: playback.state.isPlaying ? "Pause (Space)" : "Play (Space)",
                    action: onToggle
                )
                .controlSize(.large)

                IconButton(systemName: "stop.fill", help: "Stop", action: onStop)

                IconButton(systemName: "forward.end.fill", help: "Next (⌘→)", action: onNext)

                Spacer()

                if playback.hasMultipleOutputDevices {
                    Menu {
                        Button {
                            playback.selectOutputDevice(uid: nil)
                        } label: {
                            if playback.selectedOutputDeviceUID == nil {
                                Label("System Default", systemImage: "checkmark")
                            } else {
                                Text("System Default")
                            }
                        }

                        Divider()

                        ForEach(playback.outputDevices) { device in
                            Button {
                                playback.selectOutputDevice(uid: device.uid)
                            } label: {
                                if playback.selectedOutputDeviceUID == device.uid {
                                    Label(deviceLabel(for: device), systemImage: "checkmark")
                                } else {
                                    Text(deviceLabel(for: device))
                                }
                            }
                        }

                        Divider()

                        Button("Refresh Devices") {
                            playback.refreshOutputDevices()
                        }
                    } label: {
                        Label(playback.selectedOutputDeviceName, systemImage: "hifispeaker.2.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Audio output: \(playback.selectedOutputDeviceName)")
                    .accessibilityLabel("Audio output device")
                }

                IconButton(systemName: "speaker.wave.1.fill", help: "Decrease volume") {
                    playback.decreaseVolume()
                }

                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 140)

                IconButton(systemName: "speaker.wave.3.fill", help: "Increase volume") {
                    playback.increaseVolume()
                }
            }
        }
        .onAppear {
            playback.refreshOutputDevices()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func commitSeek(toElapsed elapsed: TimeInterval, context: SeekEditingContext) {
        guard let track, context.trackID == track.id else {
            DebugLog.log(
                "Transport seek ignored because slider edit track changed: " +
                "editingTrackID=\(idLabel(context.trackID)) visibleTrackID=\(idLabel(track?.id)) " +
                "requestedElapsed=\(display(elapsed))"
            )
            return
        }

        if let currentTrackID = playback.currentTrackID, currentTrackID != context.trackID {
            DebugLog.log(
                "Transport seek ignored because playback current track changed: " +
                "editingTrackID=\(idLabel(context.trackID)) currentTrackID=\(idLabel(currentTrackID)) " +
                "requestedElapsed=\(display(elapsed))"
            )
            return
        }

        if let loadingTrackID = playback.loadingTrackID, loadingTrackID != context.trackID {
            DebugLog.log(
                "Transport seek ignored because playback loading track changed: " +
                "editingTrackID=\(idLabel(context.trackID)) loadingTrackID=\(idLabel(loadingTrackID)) " +
                "requestedElapsed=\(display(elapsed))"
            )
            return
        }

        playback.seek(to: elapsed + context.cueStart)
    }

    private struct SeekEditingContext: Equatable {
        let trackID: AudioTrack.ID
        let cueStart: TimeInterval

        init(track: AudioTrack) {
            trackID = track.id
            cueStart = track.cueStart ?? 0
        }
    }

    private func idLabel(_ id: AudioTrack.ID?) -> String {
        guard let id else {
            return "nil"
        }

        return idLabel(id)
    }

    private func idLabel(_ id: AudioTrack.ID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func display(_ time: TimeInterval) -> String {
        String(format: "%.2f", time)
    }

    private func deviceLabel(for device: AudioOutputDevice) -> String {
        device.isDefault ? "\(device.name) (Default)" : device.name
    }
}

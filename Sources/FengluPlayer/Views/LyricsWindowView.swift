import AppKit
import Combine
import SwiftUI

struct LyricsWindowView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController
    @ObservedObject var playbackClock: PlaybackClock
    @ObservedObject var windowState: LyricsWindowState

    @State private var document: LyricsDocument = .empty
    @State private var loadedTrackID: AudioTrack.ID?
    @State private var isLoading = false
    @State private var lyricsTask: Task<Void, Never>?
    @State private var lyricsGeneration = 0
    @State private var window: NSWindow?

    @AppStorage(LyricsConfiguration.onlineLookupEnabledKey)
    private var isOnlineLookupEnabled = LyricsConfiguration.defaultOnlineLookupEnabled
    @AppStorage(LyricsConfiguration.fontSizeKey)
    private var fontSize = LyricsConfiguration.defaultFontSize
    @AppStorage(LyricsConfiguration.alwaysOnTopKey)
    private var isAlwaysOnTop = false
    @AppStorage(LyricsConfiguration.opacityKey)
    private var opacity = LyricsConfiguration.defaultOpacity

    private let resolver = LyricsResolver()
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var track: AudioTrack? {
        store.activeTrack ?? store.selectedTrack
    }

    private var activeLineID: LyricsLine.ID? {
        document.activeLineID(at: playback.displayElapsed(for: track))
    }

    var body: some View {
        VStack(spacing: 0) {
            LyricsHeaderView(track: track, document: document, isLoading: isLoading)

            Divider()

            LyricsControlsView(
                fontSize: $fontSize,
                isOnlineLookupEnabled: $isOnlineLookupEnabled,
                isAlwaysOnTop: $isAlwaysOnTop,
                opacity: $opacity
            )

            Divider()

            if track == nil {
                LyricsEmptyView(
                    title: "No Track",
                    systemImage: "music.note",
                    message: "Select or play a track to view lyrics."
                )
            } else if isLoading {
                LyricsEmptyView(
                    title: "Loading Lyrics",
                    systemImage: "text.magnifyingglass",
                    message: "Checking local files, cache, and configured online sources."
                )
            } else if document.isEmpty {
                LyricsEmptyView(
                    title: "No Lyrics",
                    systemImage: "text.quote",
                    message: "No matching .lrc or .txt file was found."
                )
            } else {
                LyricsLinesView(
                    document: document,
                    activeLineID: activeLineID,
                    fontSize: fontSize
                )
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .background {
            WindowAccessor { resolvedWindow in
                window = resolvedWindow
                applyWindowPresentationSettings(to: resolvedWindow)
                updateWindowTitle(resolvedWindow)
            }
        }
        .onAppear {
            windowState.isPresented = true
            DebugLog.log("Lyrics window appeared")
            reloadLyricsIfNeeded(force: true)
            playback.refresh()
            applyWindowPresentationSettings()
            updateWindowTitle()
        }
        .onDisappear {
            lyricsTask?.cancel()
            windowState.isPresented = false
            DebugLog.log("Lyrics window disappeared; active lookup cancelled")
        }
        .onReceive(clock) { _ in
            playback.refresh()
        }
        .onChange(of: track?.id) {
            reloadLyricsIfNeeded(force: true)
        }
        .onChange(of: isAlwaysOnTop) {
            applyWindowPresentationSettings()
        }
        .onChange(of: opacity) {
            applyWindowPresentationSettings()
        }
        .onChange(of: isOnlineLookupEnabled) {
            reloadLyricsIfNeeded(force: true)
        }
    }

    private func reloadLyricsIfNeeded(force: Bool = false) {
        guard let track else {
            DebugLog.log("Lyrics reload skipped because no track is selected")
            loadedTrackID = nil
            document = .empty
            isLoading = false
            lyricsTask?.cancel()
            return
        }

        guard force || loadedTrackID != track.id else {
            DebugLog.log("Lyrics reload skipped because track is already loaded: \(track.title)")
            return
        }

        DebugLog.log("Lyrics reload started for \(track.title) (\(track.url.path))")
        loadedTrackID = track.id
        document = .empty
        isLoading = true
        lyricsTask?.cancel()

        // A reload for the same track (Online toggled) supersedes the earlier
        // task too, so the track ID alone cannot tell a stale result apart.
        lyricsGeneration += 1
        let generation = lyricsGeneration
        let trackID = track.id
        lyricsTask = Task {
            let resolvedDocument = await resolver.lyrics(for: track)
            await MainActor.run {
                guard !Task.isCancelled, lyricsGeneration == generation, loadedTrackID == trackID else {
                    DebugLog.log("Lyrics reload result ignored because a newer lookup replaced it")
                    return
                }

                document = resolvedDocument
                isLoading = false
                updateWindowTitle()
                DebugLog.log(
                    "Lyrics reload finished for \(track.title); " +
                    "source='\(resolvedDocument.sourceDescription)' lines=\(resolvedDocument.lines.count)"
                )
            }
        }
    }

    private func applyWindowPresentationSettings(to resolvedWindow: NSWindow? = nil) {
        guard let window = resolvedWindow ?? window else {
            return
        }

        let clampedOpacity = min(
            max(opacity, LyricsConfiguration.minimumOpacity),
            LyricsConfiguration.maximumOpacity
        )
        if opacity != clampedOpacity {
            opacity = clampedOpacity
        }

        window.level = isAlwaysOnTop ? .floating : .normal
        window.alphaValue = clampedOpacity
        window.isOpaque = clampedOpacity >= LyricsConfiguration.maximumOpacity
    }

    private func updateWindowTitle(_ resolvedWindow: NSWindow? = nil) {
        guard let window = resolvedWindow ?? window else {
            return
        }

        window.title = "Lyrics"
    }
}

private struct LyricsHeaderView: View {
    var track: AudioTrack?
    var document: LyricsDocument
    var isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "text.quote")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? "Lyrics")
                    .font(.headline)
                    .lineLimit(1)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !document.sourceDescription.isEmpty && !isLoading {
                    Text(document.sourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if !document.isEmpty {
                Text(document.displayKind)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var detailText: String {
        if let artist = track?.artist, let album = track?.album {
            return "\(artist) - \(album)"
        }

        if let artist = track?.artist {
            return artist
        }

        return track?.fileName ?? "Sidecar lyrics"
    }
}

private struct LyricsControlsView: View {
    @Binding var fontSize: Double
    @Binding var isOnlineLookupEnabled: Bool
    @Binding var isAlwaysOnTop: Bool
    @Binding var opacity: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Text Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "\(Int(fontSize.rounded())) pt",
                    value: $fontSize,
                    in: LyricsConfiguration.minimumFontSize...LyricsConfiguration.maximumFontSize,
                    step: 1
                )
                .labelsHidden()

                Text("\(Int(fontSize.rounded())) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Spacer()

                Toggle("Online", isOn: $isOnlineLookupEnabled)
                    .toggleStyle(.checkbox)

                Toggle("Always on Top", isOn: $isAlwaysOnTop)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Text("Opacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(
                    value: $opacity,
                    in: LyricsConfiguration.minimumOpacity...LyricsConfiguration.maximumOpacity
                )

                Text("\(Int((opacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct LyricsEmptyView: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LyricsLinesView: View {
    var document: LyricsDocument
    var activeLineID: LyricsLine.ID?
    var fontSize: Double

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: max(10, fontSize * 0.65)) {
                    ForEach(document.lines) { line in
                        LyricsLineRow(
                            line: line,
                            isActive: line.id == activeLineID,
                            fontSize: fontSize
                        )
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .onChange(of: activeLineID) {
                guard let activeLineID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(activeLineID, anchor: .center)
                }
            }
        }
    }
}

private struct LyricsLineRow: View {
    var line: LyricsLine
    var isActive: Bool
    var fontSize: Double

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: fontSize, weight: isActive ? .bold : .regular))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .lineSpacing(max(4, fontSize * 0.25))
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, isActive ? 9 : 6)
    }
}

import CoreAudio
import Foundation

struct CueBoundaryAdvanceRequest: Equatable, Sendable {
    let id: UUID
    let sourceTrackID: AudioTrack.ID
    let route: DecoderRoute
}

@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?

    func setCurrentTime(_ value: TimeInterval) {
        if currentTime != value {
            currentTime = value
        }
    }

    func setDuration(_ value: TimeInterval?) {
        if duration != value {
            duration = value
        }
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published var state: PlaybackState = .stopped
    @Published var route: DecoderRoute = .idle
    /// Playback position and duration live on a separate observable so the
    /// 10 Hz position refresh only invalidates the views that display time
    /// (transport bar, lyrics), not the playlist table and sidebar.
    let clock = PlaybackClock()
    var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.setCurrentTime(newValue) }
    }
    var duration: TimeInterval? {
        get { clock.duration }
        set { clock.setDuration(newValue) }
    }
    @Published private(set) var loadingTrackID: AudioTrack.ID?
    @Published private(set) var currentTrackID: AudioTrack.ID?
    @Published private(set) var cueBoundaryAdvanceRequest: CueBoundaryAdvanceRequest?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedOutputDeviceUID: String?
    @Published var volume: Float = 0.85 {
        didSet {
            let clampedVolume = Self.clampedVolume(volume)
            if volume != clampedVolume {
                volume = clampedVolume
            }

            nativeBackend.setVolume(volume)
            ffmpegBackend.setVolume(volume)
        }
    }

    private let nativeBackend = NativePlaybackBackend()
    private let ffmpegBackend = FFmpegPlaybackBackend()
    private var outputDeviceMonitor: AudioOutputDeviceMonitor?
    private var appliedOutputDeviceID: AudioDeviceID?
    private var activeTrack: AudioTrack?
    private let seamlessNativeCueContinuationEarlyTolerance: TimeInterval = 0.01
    private let seamlessCueContinuationLateTolerance: TimeInterval = 0.50
    private let cueBoundaryEpsilon: TimeInterval = 0.005
    private weak var activeBackend: (any PlaybackBackend)?
    private var playbackRequestID = UUID()
    private var activePlayTask: Task<Void, Never>?
    private var seamlessNativeCueContinuationTrackID: AudioTrack.ID?
    private var seamlessFFmpegCueContinuationTrackID: AudioTrack.ID?

    init() {
        refreshOutputDevices()
        outputDeviceMonitor = AudioOutputDeviceMonitor { [weak self] in
            self?.refreshOutputDevices()
        }
    }

    var hasMultipleOutputDevices: Bool {
        outputDevices.count > 1
    }

    var selectedOutputDeviceName: String {
        selectedOutputDevice?.name ?? "System Default"
    }

    func refreshOutputDevices() {
        let previousDevices = outputDevices
        let previousSelectedUID = selectedOutputDeviceUID
        let previouslyAppliedDeviceID = appliedOutputDeviceID
        outputDevices = AudioOutputDeviceDiscovery.devices()

        let selectedDeviceDisappeared = previousSelectedUID.map { uid in
            !outputDevices.contains(where: { $0.uid == uid })
        } ?? false
        let appliedDeviceDisappeared = previouslyAppliedDeviceID.map { id in
            !outputDevices.contains(where: { $0.id == id })
        } ?? false
        if selectedDeviceDisappeared {
            // Only an explicitly chosen device needs a substitute.
            let replacement = nextAvailableDevice(
                after: previouslyAppliedDeviceID,
                previousDevices: previousDevices
            )
            selectedOutputDeviceUID = replacement?.uid
            DebugLog.log(
                "Playback selected output disappeared: uid='\(previousSelectedUID ?? "<none>")' " +
                "replacement='\(replacement?.name ?? "none")'"
            )
        } else if appliedDeviceDisappeared, previousSelectedUID == nil {
            // "System Default" stays selected: the resolved device below is
            // whatever macOS now reports as the default output, and a later
            // default-device notification re-resolves it again if needed.
            DebugLog.log("Playback default output disappeared; following the new system default")
        }

        let resolvedDeviceID = resolvedOutputDeviceID
        if previouslyAppliedDeviceID != resolvedDeviceID {
            handleOutputDeviceChange(
                from: previouslyAppliedDeviceID,
                to: resolvedDeviceID,
                reason: "device list refresh"
            )
        }
    }

    func selectOutputDevice(uid: String?) {
        let previouslyAppliedDeviceID = appliedOutputDeviceID
        selectedOutputDeviceUID = uid
        let resolvedDeviceID = resolvedOutputDeviceID
        guard previouslyAppliedDeviceID != resolvedDeviceID else {
            return
        }

        handleOutputDeviceChange(
            from: previouslyAppliedDeviceID,
            to: resolvedDeviceID,
            reason: "user selection"
        )
    }

    func increaseVolume() {
        setVolume(volume + 0.05)
    }

    func decreaseVolume() {
        setVolume(volume - 0.05)
    }

    func setVolume(_ volume: Float) {
        self.volume = Self.clampedVolume(volume)
    }

    func beginTransition(to track: AudioTrack, routePolicy: PlaybackRoutePolicy = .automatic) {
        activePlayTask?.cancel()
        activePlayTask = nil
        playbackRequestID = UUID()
        DebugLog.log(
            "Playback begin transition: \(trackDebugDescription(track)) " +
            "routePolicy=\(routePolicy.debugDescription) stateBefore=\(state.title) " +
            "routeBefore=\(route.rawValue) currentBefore=\(display(currentTime))"
        )

        if canSeamlesslyContinueNative(to: track, routePolicy: routePolicy) {
            seamlessNativeCueContinuationTrackID = track.id
            seamlessFFmpegCueContinuationTrackID = nil
            state = .loading
            loadingTrackID = track.id
            currentTrackID = nil
            currentTime = nativeBackend.currentTime
            activeBackend = nativeBackend
            route = .native
            duration = nativeBackend.duration ?? track.duration
            DebugLog.log(
                "Playback prepared seamless native CUE continuation without pausing: " +
                "\(trackDebugDescription(track)) current=\(display(currentTime))"
            )
            return
        }

        if canSeamlesslyContinueFFmpeg(to: track, routePolicy: routePolicy) {
            seamlessNativeCueContinuationTrackID = nil
            seamlessFFmpegCueContinuationTrackID = track.id
            state = .loading
            loadingTrackID = track.id
            currentTrackID = nil
            currentTime = ffmpegBackend.currentTime
            activeBackend = ffmpegBackend
            route = .ffmpeg
            duration = ffmpegBackend.duration ?? track.duration
            DebugLog.log(
                "Playback prepared seamless FFmpeg CUE continuation without stopping: " +
                "\(trackDebugDescription(track)) current=\(display(currentTime))"
            )
            return
        }

        seamlessNativeCueContinuationTrackID = nil
        seamlessFFmpegCueContinuationTrackID = nil
        state = .loading
        loadingTrackID = track.id
        currentTrackID = nil
        currentTime = track.startTimeForPlayback
        if canReuseNativeBackend(for: track) {
            activeBackend = nativeBackend
            route = .native
            duration = nativeBackend.duration ?? track.duration
            nativeBackend.pause()
        } else {
            activeBackend?.stop()
            activeBackend = nil
            route = .idle
            duration = track.duration
        }
    }

    func play(track: AudioTrack, routePolicy: PlaybackRoutePolicy = .automatic) async {
        activePlayTask?.cancel()
        activeTrack = track
        let requestID = UUID()
        playbackRequestID = requestID
        let playTask = Task { @MainActor in
            await self.performPlay(
                track: track,
                routePolicy: routePolicy,
                requestID: requestID
            )
        }
        activePlayTask = playTask
        await playTask.value
        if playbackRequestID == requestID {
            activePlayTask = nil
        }
    }

    private func performPlay(
        track: AudioTrack,
        routePolicy: PlaybackRoutePolicy,
        requestID: UUID,
        startTimeOverride: TimeInterval? = nil,
        shouldStartPlaying: Bool = true
    ) async {
        DebugLog.log(
            "Playback play requested: \(trackDebugDescription(track)) " +
            "routePolicy=\(routePolicy.debugDescription) stateBefore=\(state.title) " +
            "routeBefore=\(route.rawValue) currentBefore=\(display(currentTime))"
        )

        do {
            let shouldSeamlesslyContinue = canSeamlesslyContinueNative(
                to: track,
                routePolicy: routePolicy,
                acceptingLoadingTransition: true
            )
            if shouldSeamlesslyContinue {
                try continueNativeSameFileWithoutSeeking(to: track, requestID: requestID)
                return
            } else if seamlessNativeCueContinuationTrackID == track.id {
                seamlessNativeCueContinuationTrackID = nil
            }
        } catch is CancellationError {
            DebugLog.log("Playback seamless native CUE continuation cancelled: title='\(track.title)'")
            seamlessNativeCueContinuationTrackID = nil
            return
        } catch {
            DebugLog.log(
                "Playback seamless native CUE continuation failed for \(idLabel(track.id)); " +
                "falling back to same-file transition: \(error.localizedDescription)"
            )
            seamlessNativeCueContinuationTrackID = nil
        }

        do {
            let shouldSeamlesslyContinue = canSeamlesslyContinueFFmpeg(
                to: track,
                routePolicy: routePolicy,
                acceptingLoadingTransition: true
            )
            if shouldSeamlesslyContinue {
                try continueFFmpegSameFileWithoutStopping(
                    to: track,
                    requestID: requestID
                )
                return
            } else if seamlessFFmpegCueContinuationTrackID == track.id {
                seamlessFFmpegCueContinuationTrackID = nil
            }
        } catch is CancellationError {
            DebugLog.log("Playback seamless FFmpeg CUE continuation cancelled: title='\(track.title)'")
            seamlessFFmpegCueContinuationTrackID = nil
            return
        } catch {
            DebugLog.log(
                "Playback seamless FFmpeg CUE continuation failed for \(idLabel(track.id)); " +
                "falling back to full prepare: \(error.localizedDescription)"
            )
            seamlessFFmpegCueContinuationTrackID = nil
        }

        if canReuseNativeBackend(for: track) {
            do {
                try await transitionNativeSameFile(to: track, requestID: requestID)
                return
            } catch is CancellationError {
                DebugLog.log("Playback native same-file transition cancelled: title='\(track.title)'")
                return
            } catch {
                DebugLog.log(
                    "Playback native same-file transition failed for \(idLabel(track.id)); " +
                    "falling back to full prepare: \(error.localizedDescription)"
                )
            }
        }

        state = .loading
        loadingTrackID = track.id
        currentTrackID = nil
        currentTime = startTimeOverride ?? track.startTimeForPlayback
        duration = track.duration
        route = .idle
        activeBackend = nil
        DebugLog.log(
            "Playback resetting backends for \(idLabel(track.id)): " +
            "targetStart=\(display(currentTime)) provisionalDuration=\(display(duration))"
        )
        nativeBackend.stop()
        let shouldUseNativeFirst = NativeFormatHeuristics.prefersNativeDecoder(for: track)
        if shouldUseNativeFirst {
            ffmpegBackend.stop()
        }

        do {
            try validatePlaybackRequest(requestID)
            if shouldUseNativeFirst {
                try await prepareNative(
                    track: track,
                    requestID: requestID,
                    startTimeOverride: startTimeOverride,
                    shouldStartPlaying: shouldStartPlaying
                )
            } else {
                DebugLog.log(
                    "Playback using FFmpeg route for \(track.url.pathExtension.uppercased()); " +
                    "native decoder is not preferred"
                )
                try await prepareFFmpeg(
                    track: track,
                    requestID: requestID,
                    startTimeOverride: startTimeOverride,
                    shouldStartPlaying: shouldStartPlaying
                )
            }
        } catch is CancellationError {
            DebugLog.log("Playback play cancelled before route finished: title='\(track.title)'")
        } catch {
            if shouldUseNativeFirst {
                DebugLog.log(
                    "Playback native route failed for \(idLabel(track.id)); trying FFmpeg: \(error.localizedDescription)"
                )
                do {
                    try validatePlaybackRequest(requestID)
                    try await prepareFFmpeg(
                        track: track,
                        requestID: requestID,
                        startTimeOverride: startTimeOverride,
                        shouldStartPlaying: shouldStartPlaying
                    )
                } catch is CancellationError {
                    DebugLog.log("Playback play cancelled before FFmpeg route finished: title='\(track.title)'")
                } catch {
                    failPlayback(track: track, error: error, requestID: requestID)
                }
            } else {
                failPlayback(track: track, error: error, requestID: requestID)
            }
        }
    }

    func togglePlayback(for track: AudioTrack?) async {
        DebugLog.log(
            "Playback toggle requested: state=\(state.title) route=\(route.rawValue) " +
            "track=\(optionalTrackDebugDescription(track))"
        )
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .loading:
            DebugLog.log("Playback toggle ignored while a track is loading")
            return
        case .stopped, .failed:
            guard let track else {
                return
            }
            await play(track: track)
        }
    }

    func resume() {
        do {
            DebugLog.log("Playback resume requested: route=\(route.rawValue) current=\(display(currentTime))")
            try activeBackend?.play()
            state = .playing
            DebugLog.log("Playback resumed: route=\(route.rawValue) current=\(display(activeBackend?.currentTime))")
        } catch {
            state = .failed(error.localizedDescription)
            loadingTrackID = nil
            currentTrackID = nil
            DebugLog.log("Playback resume failed: \(error.localizedDescription)")
        }
    }

    func pause() {
        DebugLog.log("Playback pause requested: route=\(route.rawValue) currentBefore=\(display(currentTime))")
        activeBackend?.pause()
        refresh()
        state = .paused
        DebugLog.log("Playback paused: currentNow=\(display(currentTime))")
    }

    func stop() {
        activePlayTask?.cancel()
        activePlayTask = nil
        playbackRequestID = UUID()
        DebugLog.log(
            "Playback stop requested: state=\(state.title) route=\(route.rawValue) current=\(display(currentTime))"
        )
        activeBackend?.stop()
        activeBackend = nil
        activeTrack = nil
        seamlessNativeCueContinuationTrackID = nil
        seamlessFFmpegCueContinuationTrackID = nil
        currentTime = 0
        duration = nil
        loadingTrackID = nil
        currentTrackID = nil
        route = .idle
        state = .stopped
        DebugLog.log("Playback stopped and reset")
    }

    func seek(to time: TimeInterval) {
        guard state != .loading, loadingTrackID == nil else {
            DebugLog.log(
                "Playback seek ignored during active transition: state=\(state.title) " +
                "route=\(route.rawValue) loadingTrackID=\(idLabel(loadingTrackID)) " +
                "currentTrackID=\(idLabel(currentTrackID)) current=\(display(currentTime)) requested=\(display(time))"
            )
            return
        }

        do {
            DebugLog.log(
                "Playback seek requested: route=\(route.rawValue) from=\(display(currentTime)) to=\(display(time))"
            )
            try activeBackend?.seek(to: time)
            currentTime = time
            DebugLog.log("Playback seek finished: current=\(display(currentTime))")
        } catch {
            state = .failed(error.localizedDescription)
            DebugLog.log("Playback seek failed: \(error.localizedDescription)")
        }
    }

    func refresh() {
        guard let activeBackend else {
            return
        }

        currentTime = activeBackend.currentTime
        duration = activeBackend.duration ?? duration
    }

    func shouldAdvance(from track: AudioTrack?) -> Bool {
        guard state.isPlaying else {
            return false
        }

        refresh()

        if let cueEnd = track?.cueEnd, currentTime >= cueEnd {
            DebugLog.log(
                "Playback should advance at cue end: track=\(optionalTrackDebugDescription(track)) " +
                "current=\(display(currentTime)) cueEnd=\(display(cueEnd)) lateBy=\(display(currentTime - cueEnd))"
            )
            return true
        }

        if route == .native, nativeBackend.didReachEnd {
            DebugLog.log(
                "Playback should advance after native playback ended: " +
                "current=\(display(currentTime)) duration=\(display(duration))"
            )
            return true
        }

        if let duration, duration > 0, currentTime >= duration - 0.05 {
            DebugLog.log(
                "Playback should advance at duration end: current=\(display(currentTime)) duration=\(display(duration))"
            )
            return true
        }

        return false
    }

    func displayElapsed(for track: AudioTrack?) -> TimeInterval {
        guard let cueStart = track?.cueStart else {
            return currentTime
        }

        return max(currentTime - cueStart, 0)
    }

    func displayDuration(for track: AudioTrack?) -> TimeInterval? {
        if let cueStart = track?.cueStart {
            if let cueEnd = track?.cueEnd, cueEnd > cueStart {
                return cueEnd - cueStart
            }

            if let duration, duration > cueStart {
                return duration - cueStart
            }
        }

        return duration ?? track?.duration
    }

    private func prepareNative(
        track: AudioTrack,
        requestID: UUID,
        startTimeOverride: TimeInterval? = nil,
        shouldStartPlaying: Bool = true
    ) async throws {
        DebugLog.log("Playback preparing native route: \(trackDebugDescription(track))")
        try await nativeBackend.prepare(url: track.url)
        try validatePlaybackRequest(requestID)
        nativeBackend.setVolume(volume)
        let startTime = startTimeOverride ?? track.startTimeForPlayback
        DebugLog.log(
            "Playback native seek before play: id=\(idLabel(track.id)) target=\(display(startTime))"
        )
        await nativeBackend.seekForPlayback(
            to: startTime,
            allowsTolerance: !isCueTrack(track)
        )
        try validatePlaybackRequest(requestID)
        if shouldStartPlaying {
            nativeBackend.play()
        }
        activeBackend = nativeBackend
        route = .native
        duration = nativeBackend.duration ?? track.duration
        currentTime = nativeBackend.currentTime
        loadingTrackID = nil
        currentTrackID = track.id
        configureNativeCueBoundary(for: track)
        DebugLog.log(
            "Playback native route started: title='\(track.title)' current=\(display(currentTime)) " +
            "duration=\(display(duration))"
        )
        state = shouldStartPlaying ? .playing : .paused
    }

    private func canReuseNativeBackend(for track: AudioTrack) -> Bool {
        route == .native &&
        NativeFormatHeuristics.prefersNativeDecoder(for: track) &&
        nativeBackend.isPrepared(for: track.url)
    }

    private func isCueTrack(_ track: AudioTrack) -> Bool {
        track.source == .cue || track.cueStart != nil || track.cueEnd != nil
    }

    private func canSeamlesslyContinueNative(
        to track: AudioTrack,
        routePolicy: PlaybackRoutePolicy,
        acceptingLoadingTransition: Bool = false
    ) -> Bool {
        guard routePolicy == .cueAutoAdvance,
              track.source == .cue,
              track.cueStart != nil,
              route == .native,
              nativeBackend.isPrepared(for: track.url)
        else {
            return false
        }

        if acceptingLoadingTransition {
            guard seamlessNativeCueContinuationTrackID == track.id else {
                return false
            }
        } else if currentTrackID == track.id {
            return false
        }

        let stateAllowsContinuation: Bool
        if state == .playing {
            stateAllowsContinuation = true
        } else {
            stateAllowsContinuation = acceptingLoadingTransition &&
                state == .loading &&
                loadingTrackID == track.id
        }
        guard stateAllowsContinuation else {
            return false
        }

        let target = track.startTimeForPlayback
        let nativeTime = nativeBackend.currentTime
        let offset = nativeTime - target
        let canContinue = offset >= -seamlessNativeCueContinuationEarlyTolerance
        if !canContinue {
            DebugLog.log(
                "Playback seamless native CUE continuation unavailable: " +
                "target=\(display(target)) nativeCurrent=\(display(nativeTime)) offset=\(display(offset)) " +
                "earlyTolerance=\(display(seamlessNativeCueContinuationEarlyTolerance))"
            )
        }
        return canContinue
    }

    private func canSeamlesslyContinueFFmpeg(
        to track: AudioTrack,
        routePolicy: PlaybackRoutePolicy,
        acceptingLoadingTransition: Bool = false
    ) -> Bool {
        guard track.source == .cue,
              track.cueStart != nil,
              route == .ffmpeg,
              ffmpegBackend.isPrepared(for: track.url)
        else {
            return false
        }

        guard routePolicy == .cueAutoAdvance,
              !NativeFormatHeuristics.prefersNativeDecoder(for: track)
        else {
            return false
        }

        if acceptingLoadingTransition {
            guard seamlessFFmpegCueContinuationTrackID == track.id else {
                return false
            }
        } else if currentTrackID == track.id {
            return false
        }

        let stateAllowsContinuation: Bool
        if state == .playing {
            stateAllowsContinuation = true
        } else {
            stateAllowsContinuation = acceptingLoadingTransition &&
                state == .loading &&
                loadingTrackID == track.id
        }
        guard stateAllowsContinuation else {
            return false
        }

        let target = track.startTimeForPlayback
        let ffmpegTime = ffmpegBackend.currentTime
        if let cueEnd = track.cueEnd,
           ffmpegTime >= cueEnd - cueBoundaryEpsilon {
            DebugLog.log(
                "Playback seamless FFmpeg CUE continuation unavailable: target CUE already ended " +
                "target=\(display(target)) cueEnd=\(display(cueEnd)) ffmpegCurrent=\(display(ffmpegTime)) " +
                "boundaryEpsilon=\(display(cueBoundaryEpsilon))"
            )
            return false
        }

        let offset = ffmpegTime - target
        let canContinue =
            offset >= -seamlessNativeCueContinuationEarlyTolerance &&
            offset <= seamlessCueContinuationLateTolerance
        if !canContinue {
            DebugLog.log(
                "Playback seamless FFmpeg CUE continuation unavailable: " +
                "target=\(display(target)) ffmpegCurrent=\(display(ffmpegTime)) offset=\(display(offset)) " +
                "earlyTolerance=\(display(seamlessNativeCueContinuationEarlyTolerance)) " +
                "lateTolerance=\(display(seamlessCueContinuationLateTolerance))"
            )
        }
        return canContinue
    }

    private func continueNativeSameFileWithoutSeeking(to track: AudioTrack, requestID: UUID) throws {
        DebugLog.log(
            "Playback native seamless CUE continuation: \(trackDebugDescription(track)) " +
            "nativeCurrent=\(display(nativeBackend.currentTime))"
        )
        try validatePlaybackRequest(requestID)
        seamlessNativeCueContinuationTrackID = nil
        nativeBackend.setVolume(volume)
        activeBackend = nativeBackend
        route = .native
        duration = nativeBackend.duration ?? track.duration
        currentTime = nativeBackend.currentTime
        loadingTrackID = nil
        currentTrackID = track.id
        configureNativeCueBoundary(for: track)
        state = .playing
    }

    private func continueFFmpegSameFileWithoutStopping(
        to track: AudioTrack,
        requestID: UUID
    ) throws {
        DebugLog.log(
            "Playback FFmpeg seamless CUE continuation: \(trackDebugDescription(track)) " +
            "ffmpegCurrent=\(display(ffmpegBackend.currentTime))"
        )
        try validatePlaybackRequest(requestID)
        seamlessFFmpegCueContinuationTrackID = nil
        ffmpegBackend.setVolume(volume)
        configureFFmpegCueBoundary(for: track)
        activeBackend = ffmpegBackend
        route = .ffmpeg
        duration = ffmpegBackend.duration ?? track.duration
        currentTime = ffmpegBackend.currentTime
        loadingTrackID = nil
        currentTrackID = track.id
        nativeBackend.setBoundaryTime(nil, onReached: nil)
        state = .playing
    }

    private func transitionNativeSameFile(to track: AudioTrack, requestID: UUID) async throws {
        DebugLog.log(
            "Playback native same-file transition: \(trackDebugDescription(track)) " +
            "fromCurrent=\(display(currentTime)) target=\(display(track.startTimeForPlayback))"
        )
        state = .loading
        duration = nativeBackend.duration ?? track.duration
        activeBackend = nativeBackend
        route = .native
        nativeBackend.setVolume(volume)
        try validatePlaybackRequest(requestID)
        await nativeBackend.seekForPlayback(
            to: track.startTimeForPlayback,
            allowsTolerance: !isCueTrack(track)
        )
        try validatePlaybackRequest(requestID)
        nativeBackend.play()
        currentTime = nativeBackend.currentTime
        loadingTrackID = nil
        currentTrackID = track.id
        configureNativeCueBoundary(for: track)
        state = .playing
        DebugLog.log(
            "Playback native same-file transition started: title='\(track.title)' " +
            "current=\(display(currentTime)) duration=\(display(duration))"
        )
    }

    private func configureNativeCueBoundary(for track: AudioTrack) {
        ffmpegBackend.setBoundaryTime(nil, onReached: nil)
        guard route == .native else {
            nativeBackend.setBoundaryTime(nil, onReached: nil)
            return
        }

        guard let cueEnd = track.cueEnd, cueEnd > track.startTimeForPlayback else {
            nativeBackend.setBoundaryTime(nil, onReached: nil)
            return
        }

        let trackID = track.id
        nativeBackend.setBoundaryTime(cueEnd) { [weak self] in
            self?.cueBoundaryReached(route: .native, trackID: trackID, cueEnd: cueEnd)
        }
    }

    private func configureFFmpegCueBoundary(
        for track: AudioTrack,
        requiresFFmpegRoute: Bool = true
    ) {
        nativeBackend.setBoundaryTime(nil, onReached: nil)
        guard !requiresFFmpegRoute || route == .ffmpeg else {
            ffmpegBackend.setBoundaryTime(nil, onReached: nil)
            return
        }

        guard let cueEnd = track.cueEnd, cueEnd > track.startTimeForPlayback else {
            ffmpegBackend.setBoundaryTime(nil, onReached: nil)
            return
        }

        let trackID = track.id
        ffmpegBackend.setBoundaryTime(cueEnd, mode: ffmpegBoundaryMode(for: track)) { [weak self] in
            self?.cueBoundaryReached(route: .ffmpeg, trackID: trackID, cueEnd: cueEnd)
        }
    }

    private func cueBoundaryReached(route expectedRoute: DecoderRoute, trackID: AudioTrack.ID, cueEnd: TimeInterval) {
        guard route == expectedRoute,
              currentTrackID == trackID,
              state.isPlaying
        else {
            DebugLog.log(
                "Playback ignored stale \(expectedRoute.rawValue) cue boundary: track=\(idLabel(trackID)) " +
                "currentTrack=\(idLabel(currentTrackID)) state=\(state.title) route=\(route.rawValue)"
            )
            return
        }

        refresh()
        DebugLog.log(
            "Playback \(expectedRoute.rawValue) cue boundary advance requested: track=\(idLabel(trackID)) " +
            "current=\(display(currentTime)) cueEnd=\(display(cueEnd))"
        )
        cueBoundaryAdvanceRequest = CueBoundaryAdvanceRequest(
            id: UUID(),
            sourceTrackID: trackID,
            route: expectedRoute
        )
    }

    private func prepareFFmpeg(
        track: AudioTrack,
        requestID: UUID,
        startTimeOverride: TimeInterval? = nil,
        shouldStartPlaying: Bool = true
    ) async throws {
        DebugLog.log("Playback preparing FFmpeg route: \(trackDebugDescription(track))")
        try await ffmpegBackend.prepare(
            url: track.url,
            segmentStartTime: track.startTimeForPlayback
        )
        try validatePlaybackRequest(requestID)
        ffmpegBackend.setVolume(volume)
        configureFFmpegCueBoundary(for: track, requiresFFmpegRoute: false)
        let startTime = startTimeOverride ?? track.startTimeForPlayback
        DebugLog.log(
            "Playback FFmpeg seek before play: id=\(idLabel(track.id)) target=\(display(startTime))"
        )
        try ffmpegBackend.seek(to: startTime)
        try validatePlaybackRequest(requestID)
        if shouldStartPlaying {
            try ffmpegBackend.play()
        }
        activeBackend = ffmpegBackend
        route = .ffmpeg
        duration = ffmpegBackend.duration ?? track.duration
        currentTime = ffmpegBackend.currentTime
        loadingTrackID = nil
        currentTrackID = track.id
        nativeBackend.setBoundaryTime(nil, onReached: nil)
        DebugLog.log(
            "Playback FFmpeg route started: title='\(track.title)' current=\(display(currentTime)) " +
            "duration=\(display(duration))"
        )
        state = shouldStartPlaying ? .playing : .paused
    }

    private func ffmpegBoundaryMode(for track: AudioTrack) -> FFmpegBoundaryMode {
        if !NativeFormatHeuristics.prefersNativeDecoder(for: track) {
            return .continueThroughBoundary
        }

        return .stopAtBoundary
    }

    private func validatePlaybackRequest(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard playbackRequestID == requestID else {
            throw CancellationError()
        }
    }

    private func failPlayback(track: AudioTrack, error: Error, requestID: UUID) {
        guard playbackRequestID == requestID else {
            DebugLog.log(
                "Playback ignored stale failure for \(trackDebugDescription(track)): \(error.localizedDescription)"
            )
            return
        }

        state = .failed(error.localizedDescription)
        loadingTrackID = nil
        currentTrackID = nil
        activeTrack = nil
        seamlessNativeCueContinuationTrackID = nil
        seamlessFFmpegCueContinuationTrackID = nil
        route = .idle
        activeBackend = nil
        DebugLog.log(
            "Playback failed for \(trackDebugDescription(track)): \(error.localizedDescription)"
        )
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(format: "%.2f", time)
    }

    private func trackDebugDescription(_ track: AudioTrack) -> String {
        "id=\(idLabel(track.id)) title='\(track.title)' source=\(track.source.rawValue) " +
        "file='\(track.url.lastPathComponent)' start=\(display(track.cueStart)) end=\(display(track.cueEnd))"
    }

    private func optionalTrackDebugDescription(_ track: AudioTrack?) -> String {
        guard let track else {
            return "<none>"
        }

        return trackDebugDescription(track)
    }

    private func idLabel(_ id: AudioTrack.ID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func idLabel(_ id: AudioTrack.ID?) -> String {
        guard let id else {
            return "nil"
        }

        return idLabel(id)
    }

    private var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputDeviceUID else {
            return nil
        }

        return outputDevices.first { $0.uid == selectedOutputDeviceUID }
    }

    private var resolvedOutputDeviceID: AudioDeviceID? {
        if let selectedOutputDevice {
            return selectedOutputDevice.id
        }

        guard selectedOutputDeviceUID == nil else {
            return nil
        }

        let defaultDeviceID = AudioOutputDeviceDiscovery.defaultOutputDeviceID()
        return outputDevices.first(where: { $0.id == defaultDeviceID })?.id
            ?? outputDevices.first(where: \.isDefault)?.id
            ?? outputDevices.first?.id
    }

    private func nextAvailableDevice(
        after removedDeviceID: AudioDeviceID?,
        previousDevices: [AudioOutputDevice]
    ) -> AudioOutputDevice? {
        guard !outputDevices.isEmpty else {
            return nil
        }

        guard let removedDeviceID,
              let removedIndex = previousDevices.firstIndex(where: { $0.id == removedDeviceID })
        else {
            return outputDevices.first(where: \.isDefault) ?? outputDevices.first
        }

        let orderedCandidates = Array(previousDevices.dropFirst(removedIndex + 1))
            + Array(previousDevices.prefix(removedIndex))
        for candidate in orderedCandidates {
            if let survivingDevice = outputDevices.first(where: { $0.uid == candidate.uid }) {
                return survivingDevice
            }
        }

        return outputDevices.first(where: \.isDefault) ?? outputDevices.first
    }

    private func handleOutputDeviceChange(
        from previousDeviceID: AudioDeviceID?,
        to resolvedDeviceID: AudioDeviceID?,
        reason: String
    ) {
        let shouldRecoverPlayback =
            activeTrack != nil &&
            currentTrackID == activeTrack?.id &&
            (state.isPlaying || state == .paused)

        guard shouldRecoverPlayback,
              let track = activeTrack,
              resolvedDeviceID != nil
        else {
            applyOutputDeviceSelection()
            if resolvedDeviceID == nil, state.isPlaying || state == .paused {
                DebugLog.log("Playback has no available output device; stopping active item")
                stop()
            }
            return
        }

        refresh()
        let resumeTime = max(currentTime, track.startTimeForPlayback)
        let shouldResumePlayback = state.isPlaying
        DebugLog.log(
            "Playback rebuilding after output change: reason=\(reason) " +
            "from=\(deviceIDLabel(previousDeviceID)) to=\(deviceIDLabel(resolvedDeviceID)) " +
            "track=\(idLabel(track.id)) resume=\(display(resumeTime)) " +
            "shouldResume=\(shouldResumePlayback)"
        )

        activePlayTask?.cancel()
        activePlayTask = nil
        playbackRequestID = UUID()
        nativeBackend.stop()
        ffmpegBackend.stop()
        activeBackend = nil
        seamlessNativeCueContinuationTrackID = nil
        seamlessFFmpegCueContinuationTrackID = nil
        route = .idle
        state = .loading
        loadingTrackID = track.id
        currentTrackID = nil
        currentTime = resumeTime
        duration = track.duration
        applyOutputDeviceSelection()

        let requestID = UUID()
        playbackRequestID = requestID
        let recoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.performPlay(
                track: track,
                routePolicy: .automatic,
                requestID: requestID,
                startTimeOverride: resumeTime,
                shouldStartPlaying: shouldResumePlayback
            )
            if self.playbackRequestID == requestID {
                self.activePlayTask = nil
            }
        }
        activePlayTask = recoveryTask
    }

    private func applyOutputDeviceSelection() {
        let defaultDeviceID = AudioOutputDeviceDiscovery.defaultOutputDeviceID()
        let defaultDeviceIsUsable = outputDevices.contains { $0.id == defaultDeviceID }
        let device = selectedOutputDevice
            ?? (selectedOutputDeviceUID == nil && !defaultDeviceIsUsable ? outputDevices.first : nil)
        nativeBackend.setOutputDevice(device)
        ffmpegBackend.setOutputDevice(device)
        appliedOutputDeviceID = device?.id ?? defaultDeviceID
        DebugLog.log("Playback output device selected: \(device?.name ?? "System Default")")
    }

    private func deviceIDLabel(_ id: AudioDeviceID?) -> String {
        id.map(String.init) ?? "nil"
    }

    private static func clampedVolume(_ volume: Float) -> Float {
        max(0, min(volume, 1))
    }
}

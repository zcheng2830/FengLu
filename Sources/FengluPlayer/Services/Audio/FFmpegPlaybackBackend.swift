import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum FFmpegBoundaryMode: Sendable {
    case continueThroughBoundary
    case stopAtBoundary
}

private enum PlaybackBufferScheduleResult: Equatable {
    case scheduledFull
    case scheduledThroughBoundary
    case skippedAfterBoundary
}

@MainActor
final class FFmpegPlaybackBackend: PlaybackBackend {
    private let progressiveStartupDuration: TimeInterval = 10
    private let progressiveChunkDuration: TimeInterval = 45
    private let progressivePreloadAhead: TimeInterval = 90
    private let progressiveSeekCacheDuration: TimeInterval = 180
    private let progressiveSeekCacheByteLimit: Int64 = 256 * 1024 * 1024
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var hasAttachedPlayer = false
    private var decodedAudio: DecodedAudioBuffer?
    private var seekableDecodedBuffers: [DecodedAudioBuffer] = []
    private var pendingProgressiveChunks: [DecodedAudioBuffer] = []
    private var preparedURL: URL?
    private var preparedStartTime: TimeInterval = 0
    private var progressiveSessionID = UUID()
    private var progressiveTask: Task<Void, Never>?
    private var progressiveNextStartTime: TimeInterval?
    private var progressiveRequestedEndTime: TimeInterval?
    private var progressiveBridgeEndTime: TimeInterval?
    private var isProgressiveDecodeActive = false
    private var progressiveFinishedEndTime: TimeInterval?
    private var hasScheduledPrimaryBuffer = false
    private var scheduledStartTime: TimeInterval = 0
    private var pausedTime: TimeInterval = 0
    private var pendingProgressiveResumeTime: TimeInterval?
    private var shouldPlayPendingProgressiveResume = false
    private var playStartedAt: TimeInterval?
    private var boundaryTime: TimeInterval?
    private var boundaryHandler: (() -> Void)?
    private var boundaryMode: FFmpegBoundaryMode = .continueThroughBoundary
    private var boundaryHasFired = false
    private var boundaryClosedSchedulingTime: TimeInterval?
    // AVAudioPlayerNode.stop() fires the completion handlers of the buffers it
    // flushes. Every flush bumps this generation so a boundary callback that
    // belongs to discarded audio is not mistaken for "boundary reached".
    private var boundaryCallbackGeneration: UInt64 = 0
    private var wantsPlayback = false
    private var lastRenderedAbsoluteTime: TimeInterval?
    private var configurationChangeObserver: NSObjectProtocol?
    private var volume: Float = 0.85
    private var outputDeviceID: AudioDeviceID?

    init() {
        // The engine stops itself when the output hardware changes format
        // (for example a sample-rate change in Audio MIDI Setup) without the
        // default device changing. Nothing else restarts it, so rebuild here.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        }
    }

    var duration: TimeInterval? {
        if let progressiveFinishedEndTime {
            return progressiveFinishedEndTime
        }

        guard let decodedAudio, decodedAudio.isComplete else {
            return nil
        }

        return decodedAudio.sourceEndTime
    }

    var currentTime: TimeInterval {
        guard playerNode.isPlaying else {
            return absoluteTime(forLocalTime: pausedTime)
        }

        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            let renderedSeconds = max(Double(playerTime.sampleTime), 0) / playerTime.sampleRate
            let renderedTime = clampedAbsolutePlaybackTime(scheduledStartTime + renderedSeconds)
            lastRenderedAbsoluteTime = renderedTime
            return renderedTime
        }

        if let playStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - playStartedAt
            return clampedAbsolutePlaybackTime(scheduledStartTime + elapsed)
        }

        return absoluteTime(forLocalTime: pausedTime)
    }

    func prepare(url: URL) async throws {
        try await prepare(url: url, segmentStartTime: 0)
    }

    /// Prepares playback of `url` from `segmentStartTime` to the end of the
    /// file. Every prepare decodes a short startup buffer and then continues
    /// progressively; CUE track ends are handled by the boundary observer, not
    /// by limiting the decoded range.
    func prepare(url: URL, segmentStartTime: TimeInterval) async throws {
        try Task.checkCancellation()
        let startTime = max(segmentStartTime, 0)
        if isPrepared(for: url, segmentStartTime: startTime), let decodedAudio {
            DebugLog.log(
                "FFmpeg backend reusing decoded segment: file='\(url.lastPathComponent)' " +
                "start=\(display(startTime)) frames=\(decodedAudio.buffer.frameLength)"
            )
            stop(retainingDecodedAudio: true)
            try configureEngine(for: decodedAudio)
            return
        }

        DebugLog.log(
            "FFmpeg backend prepare started: file='\(url.lastPathComponent)' " +
            "segmentStart=\(display(startTime))"
        )
        stop(retainingDecodedAudio: false)
        let decodeStartedAt = ProcessInfo.processInfo.systemUptime
        let decodedAudio = try await FFmpegAudioDecoder.decodeDetached(
            url: url,
            startTime: startTime,
            endTime: startTime + progressiveStartupDuration,
            isComplete: false,
            priority: .userInitiated
        )
        let decodeElapsed = ProcessInfo.processInfo.systemUptime - decodeStartedAt
        try Task.checkCancellation()

        var preparedAudio = decodedAudio
        let progressiveReachedEOF = decodedAudio.duration < progressiveStartupDuration - 0.25
        if progressiveReachedEOF {
            preparedAudio.isComplete = true
        }

        self.decodedAudio = preparedAudio
        seekableDecodedBuffers = [preparedAudio]
        preparedURL = url
        preparedStartTime = startTime
        progressiveSessionID = UUID()
        isProgressiveDecodeActive = !progressiveReachedEOF
        progressiveFinishedEndTime = preparedAudio.isComplete ? preparedAudio.sourceEndTime : nil
        DebugLog.log(
            "FFmpeg backend decoded audio: file='\(url.lastPathComponent)' " +
            "sourceStart=\(display(preparedAudio.sourceStartTime)) segmentDuration=\(display(preparedAudio.duration)) " +
            "absoluteDuration=\(display(duration)) sampleRate=\(display(decodedAudio.sampleRate)) " +
            "channels=\(decodedAudio.channelCount) frames=\(decodedAudio.buffer.frameLength) " +
            "pcmBytes=\(displayMegabytes(decodedAudio.estimatedPCMBytes)) progressive=\(!progressiveReachedEOF) " +
            "decodeSeconds=\(display(decodeElapsed))"
        )

        try configureEngine(for: decodedAudio)
        if isProgressiveDecodeActive {
            startProgressiveDecodeLoop(
                url: url,
                sessionID: progressiveSessionID,
                nextStartTime: preparedAudio.sourceEndTime,
                requestedEndTime: nil
            )
        }
    }

    func isPrepared(for url: URL, segmentStartTime: TimeInterval) -> Bool {
        preparedURL == url && abs(preparedStartTime - max(segmentStartTime, 0)) < 0.001
    }

    func isPrepared(for url: URL) -> Bool {
        preparedURL == url
    }

    func stop(retainingDecodedAudio: Bool) {
        if decodedAudio != nil || playerNode.isPlaying || engine.isRunning {
            DebugLog.log(
                "FFmpeg backend stop: current=\(display(currentTime)) engineRunning=\(engine.isRunning) " +
                "nodePlaying=\(playerNode.isPlaying) retainDecoded=\(retainingDecodedAudio)"
            )
        }
        stopPlayerNodeDiscardingScheduledAudio()
        engine.stop()
        hasScheduledPrimaryBuffer = false
        scheduledStartTime = 0
        pausedTime = 0
        pendingProgressiveResumeTime = nil
        shouldPlayPendingProgressiveResume = false
        playStartedAt = nil
        wantsPlayback = false
        clearBoundaryTime(resetClosedScheduling: true)

        if !retainingDecodedAudio {
            progressiveTask?.cancel()
            progressiveTask = nil
            progressiveNextStartTime = nil
            progressiveRequestedEndTime = nil
            progressiveBridgeEndTime = nil
            seekableDecodedBuffers.removeAll()
            pendingProgressiveChunks.removeAll()
            isProgressiveDecodeActive = false
            progressiveFinishedEndTime = nil
            decodedAudio = nil
            preparedURL = nil
            preparedStartTime = 0
        }
    }

    private func stopPlayerNodeDiscardingScheduledAudio() {
        boundaryCallbackGeneration &+= 1
        lastRenderedAbsoluteTime = nil
        playerNode.stop()
    }

    private func configureEngine(for decodedAudio: DecodedAudioBuffer) throws {
        if !hasAttachedPlayer {
            engine.attach(playerNode)
            hasAttachedPlayer = true
            DebugLog.log("FFmpeg backend attached player node")
        }

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: decodedAudio.buffer.format)
        playerNode.volume = volume
        try applyOutputDevice()
        try engine.start()
        DebugLog.log("FFmpeg backend audio engine started")
    }

    func play() throws {
        if !engine.isRunning {
            try engine.start()
            DebugLog.log("FFmpeg backend audio engine restarted for play")
        }

        guard !playerNode.isPlaying else {
            DebugLog.log("FFmpeg backend play ignored because player node is already playing")
            return
        }

        wantsPlayback = true
        if pendingProgressiveResumeTime != nil, !hasScheduledPrimaryBuffer {
            shouldPlayPendingProgressiveResume = true
            DebugLog.log("FFmpeg backend play deferred until progressive seek target is decoded")
            return
        }

        playerNode.play()
        playStartedAt = ProcessInfo.processInfo.systemUptime
        DebugLog.log("FFmpeg backend play: scheduledStart=\(display(scheduledStartTime)) current=\(display(currentTime))")
    }

    func pause() {
        let absolutePausedTime = currentTime
        pausedTime = localTime(forAbsoluteTime: absolutePausedTime)
        playerNode.pause()
        shouldPlayPendingProgressiveResume = false
        playStartedAt = nil
        wantsPlayback = false
        DebugLog.log(
            "FFmpeg backend pause: localPausedTime=\(display(pausedTime)) absolute=\(display(currentTime))"
        )
    }

    func stop() {
        stop(retainingDecodedAudio: false)
    }

    func seek(to time: TimeInterval) throws {
        DebugLog.log("FFmpeg backend seek requested: from=\(display(currentTime)) to=\(display(time))")
        try schedule(fromAbsoluteTime: time)
        DebugLog.log(
            "FFmpeg backend seek finished: localScheduledStart=\(display(scheduledStartTime)) " +
            "absolute=\(display(currentTime))"
        )
    }

    func setVolume(_ volume: Float) {
        self.volume = max(0, min(volume, 1))
        playerNode.volume = self.volume
    }

    func setOutputDevice(_ device: AudioOutputDevice?) {
        outputDeviceID = device?.id
        do {
            try rebuildOutputRouteAfterDeviceChange()
            DebugLog.log("FFmpeg backend output device set: \(device?.name ?? "System Default")")
        } catch {
            DebugLog.log("FFmpeg backend output device change failed: \(error.localizedDescription)")
        }
    }

    private func handleEngineConfigurationChange() {
        // Rebuilds triggered by this backend leave the engine running; only a
        // stop the engine performed on its own needs recovery.
        guard decodedAudio != nil, !engine.isRunning else {
            return
        }

        let hasActiveRouteState =
            hasScheduledPrimaryBuffer ||
            pendingProgressiveResumeTime != nil ||
            shouldPlayPendingProgressiveResume
        guard hasActiveRouteState else {
            return
        }

        // With the engine stopped the node has no render time, so the last
        // position observed while rendering is the best resume point.
        let resumeTime = wantsPlayback ? (lastRenderedAbsoluteTime ?? currentTime) : currentTime
        let shouldResumePlayback = wantsPlayback || shouldPlayPendingProgressiveResume
        DebugLog.log(
            "FFmpeg backend audio engine configuration changed; rebuilding: " +
            "resume=\(display(resumeTime)) shouldResume=\(shouldResumePlayback)"
        )
        do {
            try rebuildOutputRouteAfterDeviceChange(
                resumeTimeOverride: resumeTime,
                shouldResumePlaybackOverride: shouldResumePlayback
            )
        } catch {
            DebugLog.log("FFmpeg backend configuration change rebuild failed: \(error.localizedDescription)")
        }
    }

    private func rebuildOutputRouteAfterDeviceChange(
        resumeTimeOverride: TimeInterval? = nil,
        shouldResumePlaybackOverride: Bool? = nil
    ) throws {
        guard let decodedAudio else {
            return
        }

        let hasActiveRouteState =
            engine.isRunning ||
            playerNode.isPlaying ||
            hasScheduledPrimaryBuffer ||
            pendingProgressiveResumeTime != nil ||
            shouldPlayPendingProgressiveResume
        guard hasActiveRouteState else {
            return
        }

        let resumeTime = resumeTimeOverride ?? currentTime
        let shouldResumePlayback = shouldResumePlaybackOverride
            ?? (playerNode.isPlaying || shouldPlayPendingProgressiveResume)
        let shouldReschedule = hasScheduledPrimaryBuffer || pendingProgressiveResumeTime != nil
        DebugLog.log(
            "FFmpeg backend rebuilding output route: resume=\(display(resumeTime)) " +
            "shouldResume=\(shouldResumePlayback) shouldReschedule=\(shouldReschedule)"
        )

        stopPlayerNodeDiscardingScheduledAudio()
        engine.stop()
        engine.reset()
        hasScheduledPrimaryBuffer = false
        playStartedAt = nil

        try configureEngine(for: decodedAudio)
        guard shouldReschedule else {
            pausedTime = localTime(forAbsoluteTime: resumeTime)
            scheduledStartTime = pausedTime
            return
        }

        shouldPlayPendingProgressiveResume = shouldResumePlayback
        try schedule(fromAbsoluteTime: resumeTime)
    }

    private func applyOutputDevice() throws {
        guard let deviceID = outputDeviceID ?? AudioOutputDeviceDiscovery.defaultOutputDeviceID() else {
            return
        }

        try engine.outputNode.auAudioUnit.setDeviceID(AUAudioObjectID(deviceID))
    }

    func setBoundaryTime(
        _ time: TimeInterval?,
        mode: FFmpegBoundaryMode = .continueThroughBoundary,
        onReached: (() -> Void)?
    ) {
        boundaryTime = time.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        boundaryHandler = boundaryTime == nil ? nil : onReached
        boundaryMode = mode
        boundaryHasFired = false
        boundaryClosedSchedulingTime = nil

        // The sample-accurate callback is attached when a buffer containing the
        // boundary is scheduled. Audio that is already queued when the boundary
        // is set (the usual case after a seamless CUE continuation) is not
        // re-split, because that would mean flushing and re-queueing audible
        // audio. For those boundaries PlaybackController.shouldAdvance detects
        // the cue end on its 100 ms poll; the audio itself stays continuous.
        if let boundaryTime {
            DebugLog.log(
                "FFmpeg backend boundary observer set: time=\(display(boundaryTime)) " +
                "mode=\(mode) current=\(display(currentTime))"
            )
        }
    }

    private func clearBoundaryTime(resetClosedScheduling: Bool) {
        boundaryTime = nil
        boundaryHandler = nil
        boundaryMode = .continueThroughBoundary
        boundaryHasFired = false
        if resetClosedScheduling {
            boundaryClosedSchedulingTime = nil
        }
    }

    private func schedulePlaybackBuffer(
        _ buffer: AVAudioPCMBuffer,
        absoluteStartTime: TimeInterval,
        label: String
    ) -> PlaybackBufferScheduleResult {
        if let boundaryClosedSchedulingTime,
           absoluteStartTime >= boundaryClosedSchedulingTime - 0.0005 {
            DebugLog.log(
                "FFmpeg backend skipped post-boundary buffer after stop boundary: " +
                "label=\(label) start=\(display(absoluteStartTime)) boundary=\(display(boundaryClosedSchedulingTime))"
            )
            return .skippedAfterBoundary
        }

        guard let boundaryTime,
              boundaryHandler != nil,
              !boundaryHasFired,
              buffer.format.sampleRate > 0
        else {
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            return .scheduledFull
        }

        let sampleRate = buffer.format.sampleRate
        let frameLength = AVAudioFramePosition(buffer.frameLength)
        let absoluteEndTime = absoluteStartTime + Double(frameLength) / sampleRate
        guard boundaryTime > absoluteStartTime + 0.0005,
              boundaryTime < absoluteEndTime - 0.0005
        else {
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            return .scheduledFull
        }

        let rawBoundaryFrame = AVAudioFramePosition(
            ((boundaryTime - absoluteStartTime) * sampleRate).rounded()
        )
        let boundaryFrame = min(max(rawBoundaryFrame, 1), frameLength)
        guard let preBoundaryBuffer = copyBufferSlice(
            buffer,
            startFrame: 0,
            frameCount: AVAudioFrameCount(boundaryFrame)
        ) else {
            DebugLog.log(
                "FFmpeg backend boundary split failed; scheduling unsplit buffer: " +
                "label=\(label) start=\(display(absoluteStartTime)) boundary=\(display(boundaryTime))"
            )
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            return .scheduledFull
        }

        if boundaryMode == .stopAtBoundary {
            boundaryClosedSchedulingTime = boundaryTime
        }
        DebugLog.log(
            "FFmpeg backend scheduling boundary split: label=\(label) " +
            "start=\(display(absoluteStartTime)) boundary=\(display(boundaryTime)) " +
            "end=\(display(absoluteEndTime)) mode=\(boundaryMode) " +
            "preFrames=\(boundaryFrame) totalFrames=\(frameLength)"
        )
        let generation = boundaryCallbackGeneration
        playerNode.scheduleBuffer(
            preBoundaryBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBoundaryReached(boundaryTime, generation: generation)
            }
        }

        let postFrames = frameLength - boundaryFrame
        guard boundaryMode == .continueThroughBoundary else {
            DebugLog.log(
                "FFmpeg backend stopped scheduling at cue boundary: " +
                "time=\(display(boundaryTime)) skippedPostFrames=\(postFrames)"
            )
            return .scheduledThroughBoundary
        }

        guard postFrames > 0,
              let postBoundaryBuffer = copyBufferSlice(
                buffer,
                startFrame: boundaryFrame,
                frameCount: AVAudioFrameCount(postFrames)
              )
        else {
            return .scheduledThroughBoundary
        }

        playerNode.scheduleBuffer(postBoundaryBuffer, at: nil, options: [])
        return .scheduledFull
    }

    private func copyBufferSlice(
        _ buffer: AVAudioPCMBuffer,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard startFrame >= 0, frameCount > 0 else {
            return nil
        }

        let availableFrames = AVAudioFramePosition(buffer.frameLength) - startFrame
        guard availableFrames >= AVAudioFramePosition(frameCount),
              let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameCount),
              let source = buffer.floatChannelData,
              let destination = slice.floatChannelData
        else {
            return nil
        }

        slice.frameLength = frameCount
        let channels = Int(buffer.format.channelCount)
        let sourceStart = Int(startFrame)
        let frames = Int(frameCount)
        for channel in 0..<channels {
            destination[channel].update(
                from: source[channel].advanced(by: sourceStart),
                count: frames
            )
        }
        return slice
    }

    private func handleBoundaryReached(_ time: TimeInterval, generation: UInt64) {
        // A callback from audio flushed by a seek, stop or route rebuild
        // carries an older generation; a callback delivered after the engine
        // stopped itself did not come from audio that was actually played.
        guard generation == boundaryCallbackGeneration,
              engine.isRunning,
              let boundaryTime,
              abs(boundaryTime - time) < 0.001,
              !boundaryHasFired,
              let handler = boundaryHandler
        else {
            DebugLog.log(
                "FFmpeg backend ignored stale boundary callback: time=\(display(time)) " +
                "active=\(display(self.boundaryTime)) fired=\(boundaryHasFired) " +
                "generation=\(generation) current=\(boundaryCallbackGeneration)"
            )
            return
        }

        boundaryHasFired = true
        let mode = boundaryMode
        clearBoundaryTime(resetClosedScheduling: mode != .stopAtBoundary)
        DebugLog.log(
            "FFmpeg backend boundary reached: time=\(display(time)) current=\(display(currentTime))"
        )
        handler()
    }

    private func schedule(fromAbsoluteTime time: TimeInterval) throws {
        let shouldResumePlayback = playerNode.isPlaying || shouldPlayPendingProgressiveResume
        guard let schedulingAudio = seekableBuffer(forAbsoluteTime: time) else {
            try restartProgressiveDecodeForCacheMiss(at: time, shouldResumePlayback: shouldResumePlayback)
            return
        }

        let localTime = localTime(forAbsoluteTime: time, in: schedulingAudio)
        let clampedTime = max(0, min(localTime, schedulingAudio.duration))
        let startFrame = AVAudioFramePosition(clampedTime * schedulingAudio.sampleRate)
        let sourceBuffer = schedulingAudio.buffer
        let totalFrames = AVAudioFramePosition(sourceBuffer.frameLength)
        let remainingFrames = max(totalFrames - startFrame, 0)
        DebugLog.log(
            "FFmpeg backend scheduling buffer: requestedAbsolute=\(display(time)) local=\(display(localTime)) " +
            "clampedLocal=\(display(clampedTime)) sourceStart=\(display(schedulingAudio.sourceStartTime)) " +
            "startFrame=\(startFrame) remainingFrames=\(remainingFrames) shouldResume=\(shouldResumePlayback)"
        )
        stopPlayerNodeDiscardingScheduledAudio()

        guard remainingFrames > 0 else {
            // localTime is intentionally unclamped here; values beyond the
            // current buffer mean progressive decode has not reached the seek
            // target yet.
            if isProgressiveDecodeActive, localTime > schedulingAudio.duration {
                decodedAudio = schedulingAudio
                pausedTime = localTime
                scheduledStartTime = localTime
                pendingProgressiveResumeTime = time
                shouldPlayPendingProgressiveResume = shouldResumePlayback
                hasScheduledPrimaryBuffer = false
                playStartedAt = nil
                DebugLog.log(
                    "FFmpeg backend schedule waiting for progressive audio at absolute=\(display(time)) " +
                    "decodedEnd=\(display(schedulingAudio.sourceEndTime)) resume=\(shouldResumePlayback)"
                )
                return
            }

            decodedAudio = schedulingAudio
            pausedTime = schedulingAudio.duration
            scheduledStartTime = schedulingAudio.duration
            pendingProgressiveResumeTime = nil
            shouldPlayPendingProgressiveResume = false
            playStartedAt = nil
            DebugLog.log("FFmpeg backend schedule reached end of decoded audio")
            return
        }

        if startFrame == 0 {
            decodedAudio = schedulingAudio
            let scheduleResult = schedulePlaybackBuffer(
                sourceBuffer,
                absoluteStartTime: schedulingAudio.sourceStartTime,
                label: "decoded"
            )
            hasScheduledPrimaryBuffer = true
            scheduledStartTime = clampedTime
            pausedTime = clampedTime
            pendingProgressiveResumeTime = nil
            shouldPlayPendingProgressiveResume = false
            playStartedAt = nil
            DebugLog.log("FFmpeg backend scheduled full decoded buffer without copy")
            if scheduleResult == .scheduledFull {
                scheduleBufferedFutureChunks(after: schedulingAudio.sourceEndTime, excluding: schedulingAudio)
            }

            if shouldResumePlayback {
                try play()
            }
            return
        }

        guard let slice = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format,
            frameCapacity: AVAudioFrameCount(remainingFrames)
        ) else {
            throw PlaybackError.ffmpegDecoderFailed("Could not allocate seek buffer")
        }

        slice.frameLength = AVAudioFrameCount(remainingFrames)
        guard let source = sourceBuffer.floatChannelData, let destination = slice.floatChannelData else {
            throw PlaybackError.ffmpegDecoderFailed("Decoded PCM seek buffer is not float channel data")
        }

        let channels = Int(sourceBuffer.format.channelCount)
        let frames = Int(remainingFrames)
        for channel in 0..<channels {
            destination[channel].update(
                from: source[channel].advanced(by: Int(startFrame)),
                count: frames
            )
        }

        decodedAudio = schedulingAudio
        let scheduleResult = schedulePlaybackBuffer(
            slice,
            absoluteStartTime: schedulingAudio.sourceStartTime + clampedTime,
            label: "seek-slice"
        )
        hasScheduledPrimaryBuffer = true
        scheduledStartTime = clampedTime
        pausedTime = clampedTime
        pendingProgressiveResumeTime = nil
        shouldPlayPendingProgressiveResume = false
        playStartedAt = nil
        if scheduleResult == .scheduledFull {
            scheduleBufferedFutureChunks(after: schedulingAudio.sourceEndTime, excluding: schedulingAudio)
        }

        if shouldResumePlayback {
            try play()
        }
    }

    private func restartProgressiveDecodeForCacheMiss(
        at requestedTime: TimeInterval,
        shouldResumePlayback: Bool
    ) throws {
        guard let preparedURL else {
            throw PlaybackError.ffmpegDecoderFailed("No prepared FFmpeg file is available for seek")
        }

        let clampedTime = clampedSeekTime(requestedTime)
        stopPlayerNodeDiscardingScheduledAudio()
        hasScheduledPrimaryBuffer = false
        scheduledStartTime = clampedTime
        pausedTime = clampedTime
        playStartedAt = nil

        if let progressiveFinishedEndTime, clampedTime >= progressiveFinishedEndTime - 0.001 {
            pendingProgressiveResumeTime = nil
            shouldPlayPendingProgressiveResume = false
            cancelProgressiveDecodeSession()
            if let tailBuffer = seekableDecodedBuffers.last ?? decodedAudio {
                decodedAudio = tailBuffer
                pausedTime = max(progressiveFinishedEndTime - tailBuffer.sourceStartTime, 0)
                scheduledStartTime = pausedTime
            } else {
                decodedAudio = nil
            }
            DebugLog.log(
                "FFmpeg progressive cache miss clamped to decoded EOF: requested=\(display(requestedTime)) " +
                "end=\(display(progressiveFinishedEndTime))"
            )
            return
        }

        progressiveTask?.cancel()
        progressiveSessionID = UUID()
        isProgressiveDecodeActive = true
        progressiveFinishedEndTime = nil
        progressiveNextStartTime = clampedTime
        progressiveRequestedEndTime = nil
        progressiveBridgeEndTime = nil
        decodedAudio = nil
        seekableDecodedBuffers.removeAll()
        pendingProgressiveChunks.removeAll()
        pendingProgressiveResumeTime = clampedTime
        shouldPlayPendingProgressiveResume = shouldResumePlayback

        DebugLog.log(
            "FFmpeg progressive cache miss; restarting decode at requested seek: " +
            "requested=\(display(requestedTime)) start=\(display(clampedTime)) resume=\(shouldResumePlayback)"
        )
        startProgressiveDecodeLoop(
            url: preparedURL,
            sessionID: progressiveSessionID,
            nextStartTime: clampedTime,
            requestedEndTime: nil
        )
    }

    private var playbackEndTime: TimeInterval? {
        if let progressiveFinishedEndTime {
            return progressiveFinishedEndTime
        }

        guard let decodedAudio, decodedAudio.isComplete else {
            return nil
        }

        return decodedAudio.sourceEndTime
    }

    private func startProgressiveDecodeLoop(
        url: URL,
        sessionID: UUID,
        nextStartTime: TimeInterval,
        requestedEndTime: TimeInterval?
    ) {
        let sessionLabel = idLabel(sessionID)
        DebugLog.log(
            "FFmpeg progressive decode started: session=\(sessionLabel) file='\(url.lastPathComponent)' " +
            "nextStart=\(display(nextStartTime)) requestedEnd=\(display(requestedEndTime)) " +
            "chunk=\(display(progressiveChunkDuration))"
        )
        progressiveTask?.cancel()
        progressiveNextStartTime = nextStartTime
        progressiveRequestedEndTime = requestedEndTime
        progressiveTask = Task { [url] in
            var nextStart = nextStartTime
            while !Task.isCancelled {
                do {
                    progressiveNextStartTime = nextStart
                    if let requestedEndTime, nextStart >= requestedEndTime - 0.001 {
                        finishProgressiveDecode(sessionID: sessionID, endTime: requestedEndTime, error: nil)
                        break
                    }

                    try await waitForProgressivePreloadWindow(sessionID: sessionID, nextStartTime: nextStart)
                    let chunkStart = nextStart
                    let uncappedChunkEnd = chunkStart + progressiveChunkDuration
                    let chunkEnd = requestedEndTime.map { min($0, uncappedChunkEnd) } ?? uncappedChunkEnd
                    let requestedChunkDuration = chunkEnd - chunkStart
                    guard requestedChunkDuration > 0 else {
                        finishProgressiveDecode(sessionID: sessionID, endTime: requestedEndTime ?? chunkStart, error: nil)
                        break
                    }

                    let decodeStartedAt = ProcessInfo.processInfo.systemUptime
                    // Cancelling this task (seek, stop, session restart)
                    // aborts the C decode loop instead of letting a superseded
                    // chunk decode run to completion.
                    let chunk = try await FFmpegAudioDecoder.decodeDetached(
                        url: url,
                        startTime: chunkStart,
                        endTime: chunkEnd,
                        isComplete: false,
                        priority: .utility
                    )
                    let decodeElapsed = ProcessInfo.processInfo.systemUptime - decodeStartedAt
                    try Task.checkCancellation()
                    guard isCurrentProgressiveSession(sessionID) else {
                        DebugLog.log(
                            "FFmpeg progressive decoded chunk discarded after session change: " +
                            "session=\(sessionLabel) sourceStart=\(display(chunk.sourceStartTime)) " +
                            "duration=\(display(chunk.duration))"
                        )
                        break
                    }

                    let reachedRequestedEnd = requestedEndTime.map { chunk.sourceEndTime >= $0 - 0.25 } ?? false
                    let reachedDecoderEOF = chunk.duration < requestedChunkDuration - 0.25
                    let reachedEOF = reachedRequestedEnd || reachedDecoderEOF
                    let finishedEndTime = reachedRequestedEnd ? requestedEndTime : nil
                    installProgressiveChunk(
                        chunk,
                        sessionID: sessionID,
                        reachedEOF: reachedEOF,
                        finishedEndTime: finishedEndTime,
                        decodeElapsed: decodeElapsed
                    )
                    nextStart = chunk.sourceEndTime
                    progressiveNextStartTime = nextStart

                    if reachedEOF {
                        break
                    }
                } catch is CancellationError {
                    DebugLog.log(
                        "FFmpeg progressive decode cancelled: session=\(sessionLabel) " +
                        "file='\(url.lastPathComponent)' nextStart=\(display(nextStart))"
                    )
                    break
                } catch {
                    finishProgressiveDecode(sessionID: sessionID, endTime: nextStart, error: error)
                    break
                }
            }
        }
    }

    private func waitForProgressivePreloadWindow(sessionID: UUID, nextStartTime: TimeInterval) async throws {
        while !Task.isCancelled {
            guard isCurrentProgressiveSession(sessionID) else {
                throw CancellationError()
            }

            let queuedAhead = nextStartTime - currentTime
            if queuedAhead <= progressivePreloadAhead {
                return
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw CancellationError()
    }

    private func installProgressiveChunk(
        _ chunk: DecodedAudioBuffer,
        sessionID: UUID,
        reachedEOF: Bool,
        finishedEndTime: TimeInterval?,
        decodeElapsed: TimeInterval
    ) {
        guard isCurrentProgressiveSession(sessionID) else {
            DebugLog.log(
                "FFmpeg progressive chunk ignored because playback session changed: " +
                "session=\(idLabel(sessionID)) current=\(idLabel(progressiveSessionID)) " +
                "sourceStart=\(display(chunk.sourceStartTime))"
            )
            return
        }

        guard chunk.duration > 0 else {
            finishProgressiveDecode(sessionID: sessionID, endTime: chunk.sourceStartTime, error: nil)
            return
        }

        DebugLog.log(
            "FFmpeg progressive decoded chunk: sourceStart=\(display(chunk.sourceStartTime)) " +
            "duration=\(display(chunk.duration)) frames=\(chunk.buffer.frameLength) " +
            "pcmBytes=\(displayMegabytes(chunk.estimatedPCMBytes)) reachedEOF=\(reachedEOF) " +
            "decodeSeconds=\(display(decodeElapsed))"
        )
        rememberSeekableBuffer(chunk)

        if let resumeTime = pendingProgressiveResumeTime, !hasScheduledPrimaryBuffer {
            if chunk.sourceEndTime <= resumeTime {
                DebugLog.log(
                    "FFmpeg progressive discarded pre-seek chunk: sourceStart=\(display(chunk.sourceStartTime)) " +
                    "end=\(display(chunk.sourceEndTime)) resume=\(display(resumeTime))"
                )
                if reachedEOF {
                    pendingProgressiveResumeTime = nil
                    shouldPlayPendingProgressiveResume = false
                    finishProgressiveDecode(sessionID: sessionID, endTime: finishedEndTime ?? chunk.sourceEndTime, error: nil)
                }
                return
            }

            if chunk.sourceStartTime <= resumeTime && resumeTime < chunk.sourceEndTime {
                decodedAudio = chunk
                pendingProgressiveChunks.removeAll()
                do {
                    try schedule(fromAbsoluteTime: resumeTime)
                    pendingProgressiveResumeTime = nil
                    shouldPlayPendingProgressiveResume = false
                    DebugLog.log("FFmpeg progressive resumed after seek at absolute=\(display(resumeTime))")
                } catch {
                    finishProgressiveDecode(sessionID: sessionID, endTime: resumeTime, error: error)
                }

                if reachedEOF {
                    finishProgressiveDecode(sessionID: sessionID, endTime: finishedEndTime ?? chunk.sourceEndTime, error: nil)
                }
                return
            }

            if chunk.sourceStartTime > resumeTime {
                decodedAudio = chunk
                pendingProgressiveChunks.removeAll()
                do {
                    try schedule(fromAbsoluteTime: chunk.sourceStartTime)
                    pendingProgressiveResumeTime = nil
                    shouldPlayPendingProgressiveResume = false
                    DebugLog.log(
                        "FFmpeg progressive resumed at next decoded chunk after seek gap: " +
                        "requested=\(display(resumeTime)) resumed=\(display(chunk.sourceStartTime))"
                    )
                } catch {
                    finishProgressiveDecode(sessionID: sessionID, endTime: chunk.sourceStartTime, error: error)
                }

                if reachedEOF {
                    finishProgressiveDecode(sessionID: sessionID, endTime: finishedEndTime ?? chunk.sourceEndTime, error: nil)
                }
                return
            }
        }

        if hasScheduledPrimaryBuffer {
            let scheduleResult = schedulePlaybackBuffer(
                chunk.buffer,
                absoluteStartTime: chunk.sourceStartTime,
                label: "progressive"
            )
            switch scheduleResult {
            case .scheduledFull:
                DebugLog.log(
                    "FFmpeg progressive scheduled chunk: sourceStart=\(display(chunk.sourceStartTime)) " +
                    "duration=\(display(chunk.duration))"
                )
            case .scheduledThroughBoundary:
                DebugLog.log(
                    "FFmpeg progressive scheduled chunk through cue boundary: " +
                    "sourceStart=\(display(chunk.sourceStartTime)) duration=\(display(chunk.duration))"
                )
            case .skippedAfterBoundary:
                DebugLog.log(
                    "FFmpeg progressive skipped post-boundary chunk: " +
                    "sourceStart=\(display(chunk.sourceStartTime)) duration=\(display(chunk.duration))"
                )
            }
        } else {
            pendingProgressiveChunks.append(chunk)
            DebugLog.log("FFmpeg progressive queued chunk until initial seek schedules playback")
        }

        if reachedEOF {
            finishProgressiveDecode(sessionID: sessionID, endTime: finishedEndTime ?? chunk.sourceEndTime, error: nil)
        }
    }

    private func isCurrentProgressiveSession(_ sessionID: UUID) -> Bool {
        sessionID == progressiveSessionID && isProgressiveDecodeActive
    }

    private func scheduleBufferedFutureChunks(after absoluteTime: TimeInterval, excluding primaryBuffer: DecodedAudioBuffer?) {
        guard hasScheduledPrimaryBuffer else {
            return
        }

        // These buffers come from the same FFmpeg decode session, so their
        // AVAudioFormat should match the primary buffer that configured the engine.
        var nextExpectedStart = absoluteTime
        var scheduledBuffers: [DecodedAudioBuffer] = []
        var restartedAtGap = false
        let futureBuffers = seekableDecodedBuffers
            .filter { candidate in
                !isSameSeekableBuffer(candidate, primaryBuffer) &&
                    candidate.sourceEndTime > absoluteTime + 0.001
            }
            .sorted { $0.sourceStartTime < $1.sourceStartTime }

        if futureBuffers.isEmpty {
            restartProgressiveDecodeFromCacheGap(at: absoluteTime, through: nil, after: primaryBuffer)
            return
        }

        futureBufferLoop: for chunk in futureBuffers {
            guard chunk.sourceStartTime <= nextExpectedStart + 0.05 else {
                DebugLog.log(
                    "FFmpeg progressive future queue stopped at gap: expected=\(display(nextExpectedStart)) " +
                    "next=\(display(chunk.sourceStartTime))"
                )
                restartProgressiveDecodeFromCacheGap(
                    at: nextExpectedStart,
                    through: chunk.sourceStartTime,
                    after: primaryBuffer
                )
                restartedAtGap = true
                break
            }

            guard chunk.sourceEndTime > nextExpectedStart + 0.001 else {
                continue
            }

            let scheduleResult = schedulePlaybackBuffer(
                chunk.buffer,
                absoluteStartTime: chunk.sourceStartTime,
                label: "remembered"
            )
            switch scheduleResult {
            case .scheduledFull:
                scheduledBuffers.append(chunk)
                nextExpectedStart = chunk.sourceEndTime
                DebugLog.log(
                    "FFmpeg progressive scheduled remembered chunk: " +
                    "sourceStart=\(display(chunk.sourceStartTime)) duration=\(display(chunk.duration))"
                )
            case .scheduledThroughBoundary:
                scheduledBuffers.append(chunk)
                nextExpectedStart = boundaryClosedSchedulingTime ?? nextExpectedStart
                restartedAtGap = true
                DebugLog.log(
                    "FFmpeg progressive scheduled remembered chunk through cue boundary: " +
                    "sourceStart=\(display(chunk.sourceStartTime)) duration=\(display(chunk.duration))"
                )
                break futureBufferLoop
            case .skippedAfterBoundary:
                restartedAtGap = true
                DebugLog.log(
                    "FFmpeg progressive stopped remembered scheduling after cue boundary: " +
                    "sourceStart=\(display(chunk.sourceStartTime)) duration=\(display(chunk.duration))"
                )
                break futureBufferLoop
            }
        }

        if !scheduledBuffers.isEmpty {
            pendingProgressiveChunks.removeAll { pending in
                scheduledBuffers.contains { isSameSeekableBuffer($0, pending) }
            }
            if !restartedAtGap {
                restartProgressiveDecodeFromCacheGap(at: nextExpectedStart, through: nil, after: primaryBuffer)
            }
        }
    }

    private func restartProgressiveDecodeFromCacheGap(
        at startTime: TimeInterval,
        through bridgeEndTime: TimeInterval?,
        after primaryBuffer: DecodedAudioBuffer?
    ) {
        if primaryBuffer?.isComplete == true {
            return
        }

        guard let preparedURL else {
            DebugLog.log("FFmpeg progressive cannot restart at cache gap because no prepared URL is available")
            return
        }

        let clampedTime = clampedSeekTime(startTime)
        if let progressiveFinishedEndTime, clampedTime >= progressiveFinishedEndTime - 0.001 {
            return
        }
        if progressiveDecodeAlreadyCovers(startTime: clampedTime, requestedEndTime: bridgeEndTime) {
            DebugLog.log(
                "FFmpeg progressive restart skipped because active decoder covers gap: " +
                "start=\(display(clampedTime)) nextStart=\(display(progressiveNextStartTime))"
            )
            return
        }

        progressiveTask?.cancel()
        progressiveSessionID = UUID()
        isProgressiveDecodeActive = true
        progressiveFinishedEndTime = nil
        progressiveNextStartTime = clampedTime
        progressiveRequestedEndTime = bridgeEndTime
        progressiveBridgeEndTime = bridgeEndTime
        pendingProgressiveResumeTime = nil
        shouldPlayPendingProgressiveResume = false
        DebugLog.log(
            "FFmpeg progressive restarting decode at cache gap: " +
            "start=\(display(clampedTime)) bridgeEnd=\(display(bridgeEndTime))"
        )
        startProgressiveDecodeLoop(
            url: preparedURL,
            sessionID: progressiveSessionID,
            nextStartTime: clampedTime,
            requestedEndTime: bridgeEndTime
        )
    }

    private func progressiveDecodeAlreadyCovers(
        startTime: TimeInterval,
        requestedEndTime: TimeInterval?
    ) -> Bool {
        guard isProgressiveDecodeActive, let progressiveNextStartTime else {
            return false
        }
        guard progressiveNextStartTime <= startTime + 0.05 else {
            return false
        }
        let activeEndTime = progressiveBridgeEndTime ?? progressiveRequestedEndTime
        if let activeEndTime, activeEndTime <= startTime + 0.001 {
            return false
        }

        guard let effectiveRequestedEndTime = requestedEndTime else {
            return activeEndTime == nil
        }

        guard let activeEndTime else {
            return true
        }
        return activeEndTime >= effectiveRequestedEndTime - 0.05
    }

    private func cancelProgressiveDecodeSession() {
        progressiveTask?.cancel()
        progressiveTask = nil
        progressiveSessionID = UUID()
        progressiveNextStartTime = nil
        progressiveRequestedEndTime = nil
        progressiveBridgeEndTime = nil
        isProgressiveDecodeActive = false
    }

    private func rememberSeekableBuffer(_ buffer: DecodedAudioBuffer) {
        let alreadyKnown = seekableDecodedBuffers.contains {
            abs($0.sourceStartTime - buffer.sourceStartTime) < 0.001 &&
            abs($0.sourceEndTime - buffer.sourceEndTime) < 0.001
        }
        if !alreadyKnown {
            seekableDecodedBuffers.append(buffer)
            seekableDecodedBuffers.sort { $0.sourceStartTime < $1.sourceStartTime }
            trimSeekableBufferCache()
        }
    }

    private func trimSeekableBufferCache() {
        guard seekableDecodedBuffers.count > 1 else {
            return
        }

        let currentBuffer = decodedAudio
        let newestEndTime = seekableDecodedBuffers.map(\.sourceEndTime).max() ?? preparedStartTime
        let minimumEndTime = max(preparedStartTime, newestEndTime - progressiveSeekCacheDuration)
        var removedBuffers: [DecodedAudioBuffer] = []

        seekableDecodedBuffers.removeAll { buffer in
            let shouldRemove = !isSameSeekableBuffer(buffer, currentBuffer) && buffer.sourceEndTime < minimumEndTime
            if shouldRemove {
                removedBuffers.append(buffer)
            }
            return shouldRemove
        }

        var totalBytes = seekableDecodedBuffers.reduce(Int64(0)) { $0 + $1.estimatedPCMBytes }
        while totalBytes > progressiveSeekCacheByteLimit,
              let oldestIndex = seekableDecodedBuffers.indices.first(where: {
                  !isSameSeekableBuffer(seekableDecodedBuffers[$0], currentBuffer)
              }) {
            let removed = seekableDecodedBuffers.remove(at: oldestIndex)
            removedBuffers.append(removed)
            totalBytes -= removed.estimatedPCMBytes
            DebugLog.log(
                "FFmpeg progressive dropped cached chunk: sourceStart=\(display(removed.sourceStartTime)) " +
                "duration=\(display(removed.duration)) cacheBytes=\(totalBytes)"
            )
        }

        if !removedBuffers.isEmpty {
            pendingProgressiveChunks.removeAll { pending in
                removedBuffers.contains { isSameSeekableBuffer($0, pending) }
            }
        }
    }

    private func isSameSeekableBuffer(_ lhs: DecodedAudioBuffer, _ rhs: DecodedAudioBuffer?) -> Bool {
        guard let rhs else {
            return false
        }

        return isSameSeekableBuffer(lhs, rhs)
    }

    private func isSameSeekableBuffer(_ lhs: DecodedAudioBuffer, _ rhs: DecodedAudioBuffer) -> Bool {
        abs(lhs.sourceStartTime - rhs.sourceStartTime) < 0.001 &&
            abs(lhs.sourceEndTime - rhs.sourceEndTime) < 0.001
    }

    private func finishProgressiveDecode(sessionID: UUID, endTime: TimeInterval, error: Error?) {
        guard isCurrentProgressiveSession(sessionID) else {
            return
        }

        if let resumeTime = pendingProgressiveResumeTime, endTime <= resumeTime + 0.001 {
            pendingProgressiveResumeTime = nil
            shouldPlayPendingProgressiveResume = false
        }
        if error == nil,
           let bridgeEndTime = progressiveBridgeEndTime,
           abs(endTime - bridgeEndTime) < 0.05 {
            progressiveTask = nil
            progressiveNextStartTime = nil
            progressiveRequestedEndTime = nil
            progressiveBridgeEndTime = nil
            isProgressiveDecodeActive = false
            DebugLog.log("FFmpeg progressive bridge decode finished: end=\(display(endTime))")
            scheduleBufferedFutureChunks(after: endTime, excluding: decodedAudio)
            return
        }

        progressiveTask = nil
        progressiveNextStartTime = nil
        progressiveRequestedEndTime = nil
        progressiveBridgeEndTime = nil
        isProgressiveDecodeActive = false
        progressiveFinishedEndTime = endTime
        if let error {
            DebugLog.log(
                "FFmpeg progressive decode stopped at \(display(endTime)): \(error.localizedDescription)"
            )
        } else {
            DebugLog.log("FFmpeg progressive decode finished: end=\(display(endTime))")
        }
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(format: "%.2f", time)
    }

    private func displayMegabytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", megabytes)
    }

    private func idLabel(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func localTime(forAbsoluteTime time: TimeInterval) -> TimeInterval {
        guard let decodedAudio else {
            return max(time, 0)
        }

        return localTime(forAbsoluteTime: time, in: decodedAudio)
    }

    private func localTime(forAbsoluteTime time: TimeInterval, in buffer: DecodedAudioBuffer) -> TimeInterval {
        max(time - buffer.sourceStartTime, 0)
    }

    private func absoluteTime(forLocalTime time: TimeInterval) -> TimeInterval {
        guard let decodedAudio else {
            return max(time, 0)
        }

        return decodedAudio.sourceStartTime + max(time, 0)
    }

    private func clampedAbsolutePlaybackTime(_ localTime: TimeInterval) -> TimeInterval {
        let absoluteTime = absoluteTime(forLocalTime: localTime)
        if let playbackEndTime {
            return min(absoluteTime, playbackEndTime)
        }
        return absoluteTime
    }

    private func seekableBuffer(forAbsoluteTime time: TimeInterval) -> DecodedAudioBuffer? {
        if let containing = seekableDecodedBuffers.first(where: { buffer in
            time >= buffer.sourceStartTime && time < buffer.sourceEndTime
        }) {
            return containing
        }

        if let first = seekableDecodedBuffers.first,
           first.sourceStartTime <= preparedStartTime + 0.001,
           time <= preparedStartTime + 0.001,
           time < first.sourceStartTime {
            return first
        }

        if let last = seekableDecodedBuffers.last, !isProgressiveDecodeActive, time >= last.sourceEndTime {
            return last
        }

        return nil
    }

    private func clampedSeekTime(_ time: TimeInterval) -> TimeInterval {
        max(time, preparedStartTime)
    }
}

import AVFoundation
import Foundation

@MainActor
final class NativePlaybackBackend: PlaybackBackend {
    private static let playbackSeekToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
    /// How long prepare waits for AVPlayerItem to report whether it can play.
    private static let itemReadinessTimeout: TimeInterval = 5

    private var player: AVPlayer?
    private var preparedURL: URL?
    private(set) var duration: TimeInterval?
    private(set) var didReachEnd = false
    private var boundaryTimeObserver: Any?
    private var boundaryHandler: (() -> Void)?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackFailureObserver: NSObjectProtocol?
    private var volume: Float = 0.85
    private var outputDeviceUID: String?

    var currentTime: TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else {
            return 0
        }
        return seconds
    }

    func prepare(url: URL) async throws {
        DebugLog.log("Native backend prepare started: file='\(url.lastPathComponent)'")
        clearBoundaryTimeObserver()
        clearPlaybackEndObserver()
        didReachEnd = false
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            DebugLog.log("Native backend rejected unplayable asset: file='\(url.lastPathComponent)'")
            throw PlaybackError.nativeDecoderUnavailable(url.lastPathComponent)
        }
        try Task.checkCancellation()

        let item = AVPlayerItem(asset: asset)
        let loadedDuration = try? await asset.load(.duration)
        try Task.checkCancellation()
        if let loadedDuration, loadedDuration.seconds.isFinite {
            duration = loadedDuration.seconds
        } else {
            duration = nil
        }
        DebugLog.log(
            "Native backend asset loaded: file='\(url.lastPathComponent)' duration=\(display(duration))"
        )

        let player = AVPlayer(playerItem: item)
        player.volume = volume
        player.audioOutputDeviceUniqueID = outputDeviceUID
        self.player = player

        // `isPlayable` is only the asset's claim. The item can still fail once
        // the player tries to decode it, and nothing else would notice: the
        // player would sit at 0:00 forever. Throwing here lets the controller
        // fall back to the FFmpeg route.
        do {
            try await waitUntilReadyToPlay(item, fileName: url.lastPathComponent)
        } catch {
            if self.player === player {
                stop()
            }
            throw error
        }
        guard self.player === player else {
            throw CancellationError()
        }

        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] notification in
            let description = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "unknown error"
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let item,
                      self.player?.currentItem === item
                else {
                    return
                }

                // Treat a mid-track decode failure as the end of the track so
                // playback moves on instead of stalling silently.
                self.didReachEnd = true
                DebugLog.log(
                    "Native backend playback failed before the end: current=\(self.display(self.currentTime)) " +
                    "error='\(description)'"
                )
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let item,
                      self.player?.currentItem === item
                else {
                    return
                }

                self.didReachEnd = true
                DebugLog.log(
                    "Native backend playback ended: current=\(self.display(self.currentTime)) " +
                    "duration=\(self.display(self.duration))"
                )
            }
        }
        preparedURL = normalized(url)
    }

    private func waitUntilReadyToPlay(_ item: AVPlayerItem, fileName: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.itemReadinessTimeout
        while item.status == .unknown {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                DebugLog.log("Native backend item did not become ready in time: file='\(fileName)'")
                throw PlaybackError.nativeDecoderUnavailable(fileName)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        guard item.status == .readyToPlay else {
            DebugLog.log(
                "Native backend item failed to become ready: file='\(fileName)' " +
                "error='\(item.error?.localizedDescription ?? "unknown error")'"
            )
            throw PlaybackError.nativeDecoderUnavailable(fileName)
        }
    }

    func isPrepared(for url: URL) -> Bool {
        preparedURL == normalized(url)
    }

    func play() {
        DebugLog.log("Native backend play: current=\(display(currentTime))")
        player?.play()
    }

    func pause() {
        DebugLog.log("Native backend pause: current=\(display(currentTime))")
        player?.pause()
    }

    func stop() {
        guard let player else {
            return
        }

        DebugLog.log("Native backend stop: current=\(display(currentTime))")
        clearBoundaryTimeObserver()
        clearPlaybackEndObserver()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        preparedURL = nil
        duration = nil
        didReachEnd = false
    }

    func seek(to time: TimeInterval) {
        didReachEnd = false
        let target = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        DebugLog.log("Native backend seek requested: from=\(display(currentTime)) to=\(display(time))")
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekForPlayback(to time: TimeInterval, allowsTolerance: Bool = true) async {
        didReachEnd = false
        let target = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        let toleranceAfter = allowsTolerance && time > 0 ? Self.playbackSeekToleranceAfter : .zero
        guard let player else {
            DebugLog.log("Native backend seekForPlayback skipped because no player exists")
            return
        }

        DebugLog.log(
            "Native backend seekForPlayback requested: from=\(display(currentTime)) " +
            "to=\(display(time)) toleranceAfter=\(display(toleranceAfter.seconds))"
        )
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: toleranceAfter) { _ in
                continuation.resume()
            }
        }
        DebugLog.log("Native backend seekForPlayback completed: current=\(display(currentTime))")
    }

    func setBoundaryTime(_ time: TimeInterval?, onReached: (() -> Void)?) {
        clearBoundaryTimeObserver()
        boundaryHandler = onReached

        guard let player,
              let time,
              time.isFinite,
              time > 0
        else {
            return
        }

        let boundaryTime = CMTime(seconds: time, preferredTimescale: 600)
        let boundaryValue = NSValue(time: boundaryTime)
        boundaryTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [boundaryValue],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBoundaryReached(time)
            }
        }
        DebugLog.log(
            "Native backend boundary observer set: time=\(display(time)) current=\(display(currentTime))"
        )
    }

    func setVolume(_ volume: Float) {
        self.volume = max(0, min(volume, 1))
        player?.volume = self.volume
    }

    func setOutputDevice(_ device: AudioOutputDevice?) {
        outputDeviceUID = device?.uid
        let wasPlaying = (player?.rate ?? 0) > 0
        player?.audioOutputDeviceUniqueID = outputDeviceUID
        if wasPlaying {
            player?.play()
        }
        DebugLog.log("Native backend output device set: \(device?.name ?? "System Default")")
    }

    private func handleBoundaryReached(_ time: TimeInterval) {
        DebugLog.log(
            "Native backend boundary reached: time=\(display(time)) current=\(display(currentTime))"
        )
        let handler = boundaryHandler
        clearBoundaryTimeObserver()
        handler?()
    }

    private func clearBoundaryTimeObserver() {
        if let boundaryTimeObserver, let player {
            player.removeTimeObserver(boundaryTimeObserver)
        }
        boundaryTimeObserver = nil
        boundaryHandler = nil
    }

    private func clearPlaybackEndObserver() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
        }
        playbackFailureObserver = nil
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(format: "%.2f", time)
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}

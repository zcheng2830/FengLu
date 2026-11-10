import Foundation

@MainActor
protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval? { get }
    var currentTime: TimeInterval { get }

    func prepare(url: URL) async throws
    func play() throws
    func pause()
    func stop()
    func seek(to time: TimeInterval) throws
    func setVolume(_ volume: Float)
    func setOutputDevice(_ device: AudioOutputDevice?)
}

import AVFoundation
import FengluFFmpeg
import Foundation

// FFmpeg decoding happens off the main actor, then ownership of this buffer is
// transferred back to the main-actor playback backend. Do not share one
// AVAudioPCMBuffer instance across actors concurrently.
struct DecodedAudioBuffer: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: AVAudioChannelCount
    var sourceStartTime: TimeInterval
    var isComplete: Bool

    var estimatedPCMBytes: Int64 {
        Int64(buffer.frameLength) * Int64(channelCount) * Int64(MemoryLayout<Float>.size)
    }

    var sourceEndTime: TimeInterval {
        sourceStartTime + duration
    }
}

/// Lets the owner of a decode abort it from another thread. The C decode loop
/// polls the token between packets and during blocking file reads.
final class FFmpegDecodeCancellation: @unchecked Sendable {
    fileprivate let token: OpaquePointer?

    init() {
        token = fl_ffmpeg_cancel_token_create()
    }

    deinit {
        fl_ffmpeg_cancel_token_destroy(token)
    }

    func cancel() {
        fl_ffmpeg_cancel_token_cancel(token)
    }
}

struct FFmpegAudioDecoder: Sendable {
    /// Runs a decode off the calling actor and aborts the C decode loop as soon
    /// as the calling task is cancelled, instead of letting a superseded decode
    /// run to completion.
    static func decodeDetached(
        url: URL,
        startTime: TimeInterval,
        endTime: TimeInterval?,
        isComplete: Bool,
        priority: TaskPriority
    ) async throws -> DecodedAudioBuffer {
        let cancellation = FFmpegDecodeCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: priority) { @Sendable in
                try FFmpegAudioDecoder().decode(
                    url: url,
                    startTime: startTime,
                    endTime: endTime,
                    isComplete: isComplete,
                    cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    func decode(
        url: URL,
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil,
        isComplete: Bool = true,
        cancellation: FFmpegDecodeCancellation? = nil
    ) throws -> DecodedAudioBuffer {
        var decoded = FLDecodedAudio()
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let clampedStartTime = max(startTime, 0)
        let segmentDuration = endTime.flatMap { endTime -> TimeInterval? in
            let duration = endTime - clampedStartTime
            return duration > 0 ? duration : nil
        }

        let result = errorBuffer.withUnsafeMutableBufferPointer { errorPointer -> Int32 in
            url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
                guard let fileSystemPath, let errorBaseAddress = errorPointer.baseAddress else {
                    return -1
                }

                return fl_ffmpeg_decode_file_segment_cancellable(
                    fileSystemPath,
                    clampedStartTime,
                    segmentDuration ?? -1,
                    cancellation?.token,
                    &decoded,
                    errorBaseAddress,
                    Int32(errorPointer.count)
                )
            }
        }

        if result == FL_FFMPEG_DECODE_CANCELLED {
            throw CancellationError()
        }

        guard result == 0 else {
            let message = errorBuffer.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else {
                    return "FFmpeg could not decode this file"
                }
                return String(cString: baseAddress).nonEmpty ?? "FFmpeg could not decode this file"
            }
            throw PlaybackError.ffmpegDecoderFailed(message)
        }

        defer {
            fl_ffmpeg_free_decoded_audio(&decoded)
        }

        guard decoded.sampleRate > 0, decoded.channelCount > 0, decoded.frameCount > 0, let samples = decoded.samples else {
            throw PlaybackError.ffmpegDecoderFailed("FFmpeg returned an empty audio buffer")
        }

        let channelCount = AVAudioChannelCount(decoded.channelCount)
        let sampleRate = Double(decoded.sampleRate)
        let format = try Self.pcmFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            channelLayoutTag: decoded.channelLayoutTag
        )
        if decoded.corruptPacketCount > 0 {
            DebugLog.log(
                "FFmpeg decoder skipped \(decoded.corruptPacketCount) undecodable packet(s): " +
                "file='\(url.lastPathComponent)' start=\(String(format: "%.2f", clampedStartTime))"
            )
        }

        let frameCount = AVAudioFrameCount(decoded.frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw PlaybackError.ffmpegDecoderFailed("Could not allocate AVAudioPCMBuffer")
        }

        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else {
            throw PlaybackError.ffmpegDecoderFailed("Decoded PCM buffer is not float channel data")
        }

        let frames = Int(decoded.frameCount)
        let channels = Int(decoded.channelCount)
        for frame in 0..<frames {
            for channel in 0..<channels {
                channelData[channel][frame] = samples[(frame * channels) + channel]
            }
        }

        return DecodedAudioBuffer(
            buffer: buffer,
            duration: decoded.duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceStartTime: clampedStartTime,
            isComplete: isComplete
        )
    }

    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` only exists for
    /// mono and stereo. Surround audio needs an explicit channel layout, which
    /// the shim reports as a Core Audio layout tag matching its channel order.
    static func pcmFormat(
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        channelLayoutTag: AudioChannelLayoutTag
    ) throws -> AVAudioFormat {
        if channelCount <= 2,
           let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) {
            return format
        }

        guard channelLayoutTag != 0,
              let layout = AVAudioChannelLayout(layoutTag: channelLayoutTag),
              layout.channelCount == channelCount
        else {
            throw PlaybackError.ffmpegDecoderFailed(
                "Could not create AVAudioFormat for \(channelCount)-channel FFmpeg PCM"
            )
        }

        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    static var version: String {
        String(cString: fl_ffmpeg_version())
    }
}

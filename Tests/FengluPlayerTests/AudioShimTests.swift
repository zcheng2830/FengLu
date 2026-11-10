import AVFoundation
import Foundation
import Testing
@testable import FengluPlayer

/// Exercises the FFmpeg shim through `FFmpegAudioDecoder` with audio generated
/// at test time, so no binary fixtures are needed.
struct AudioShimTests {
    private static let sampleRate = 44_100.0
    private static let durationSeconds = 40.0

    /// Deterministic white noise: any misplaced sample shows up as a mismatch.
    private static func noiseBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for frame in 0..<Int(frameCount) {
            for channel in 0..<2 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float((state >> 40) & 0xFFFF) / Float(0xFFFF)
                channels[channel][frame] = (unit - 0.5) * 0.5
            }
        }
        return buffer
    }

    /// Writes the noise as a block-compressed lossless file. Returns nil when
    /// this machine cannot encode the format, so the test can skip.
    private static func writeLosslessFile(
        named fileName: String,
        formatID: AudioFormatID,
        in directory: URL
    ) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVEncoderBitDepthHintKey: 16
        ]
        do {
            let buffer = try noiseBuffer()
            // Scope the file so it is closed (and finalized) before decoding.
            do {
                let file = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                try file.write(from: buffer)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FengluAudioShimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Chunked playback re-opens the file and seeks for every chunk, so a
    /// segment requested at T must start at exactly the sample a decode from
    /// the beginning has at T. Packet-based codecs used to start up to one
    /// packet late.
    @Test(arguments: [
        ("noise.flac", kAudioFormatFLAC),
        ("noise.m4a", kAudioFormatAppleLossless)
    ])
    func segmentDecodeStartsOnTheRequestedSample(fileName: String, formatID: AudioFormatID) throws {
        let directory = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        guard let url = Self.writeLosslessFile(named: fileName, formatID: formatID, in: directory) else {
            // Encoder not available here; nothing to verify.
            return
        }

        let decoder = FFmpegAudioDecoder()
        let reference = try decoder.decode(url: url)
        let referenceSamples = try #require(reference.buffer.floatChannelData)
        #expect(abs(reference.duration - Self.durationSeconds) < 0.01)

        // Starts chosen to fall inside packets, including the 10 s startup
        // boundary the playback backend uses.
        for start in [10.0, 7.77, 23.456, 33.333] {
            let segment = try decoder.decode(url: url, startTime: start, endTime: start + 2)
            let segmentSamples = try #require(segment.buffer.floatChannelData)
            let expectedFrame = Int((start * Self.sampleRate).rounded())
            let comparedFrames = min(Int(segment.buffer.frameLength), 4_096)
            #expect(abs(segment.duration - 2) < 0.001, "start=\(start)")
            #expect(comparedFrames == 4_096, "start=\(start)")

            var mismatches = 0
            for frame in 0..<comparedFrames
                where segmentSamples[0][frame] != referenceSamples[0][expectedFrame + frame] ||
                    segmentSamples[1][frame] != referenceSamples[1][expectedFrame + frame] {
                mismatches += 1
            }
            #expect(mismatches == 0, "segment at \(start)s is not sample-aligned with the full decode")
        }
    }

    @Test
    func consecutiveChunksAreContiguous() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        guard let url = Self.writeLosslessFile(named: "noise.flac", formatID: kAudioFormatFLAC, in: directory) else {
            return
        }

        let decoder = FFmpegAudioDecoder()
        let reference = try decoder.decode(url: url)
        let referenceSamples = try #require(reference.buffer.floatChannelData)

        // Mirrors the backend: a startup chunk, then chunks that each start
        // where the previous one ended.
        var nextStart = 0.0
        var frameCursor = 0
        for length in [10.0, 12.5, 12.5] {
            let chunk = try decoder.decode(url: url, startTime: nextStart, endTime: nextStart + length)
            let chunkSamples = try #require(chunk.buffer.floatChannelData)
            let frames = Int(chunk.buffer.frameLength)
            var mismatches = 0
            for frame in 0..<frames where chunkSamples[0][frame] != referenceSamples[0][frameCursor + frame] {
                mismatches += 1
            }
            #expect(mismatches == 0, "chunk starting at \(nextStart)s drifted from the full decode")
            frameCursor += frames
            nextStart = chunk.sourceEndTime
        }
        #expect(frameCursor == Int(35 * Self.sampleRate))
    }

    @Test
    func cancelledDecodeThrowsCancellation() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        guard let url = Self.writeLosslessFile(named: "noise.flac", formatID: kAudioFormatFLAC, in: directory) else {
            return
        }

        let cancellation = FFmpegDecodeCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            _ = try FFmpegAudioDecoder().decode(url: url, cancellation: cancellation)
        }
    }

    @Test
    func surroundFormatsCarryAChannelLayout() throws {
        let stereo = try FFmpegAudioDecoder.pcmFormat(sampleRate: 48_000, channelCount: 2, channelLayoutTag: 0)
        #expect(stereo.channelCount == 2)

        let surround = try FFmpegAudioDecoder.pcmFormat(
            sampleRate: 48_000,
            channelCount: 6,
            channelLayoutTag: kAudioChannelLayoutTag_MPEG_5_1_A
        )
        #expect(surround.channelCount == 6)
        #expect(surround.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)

        // More than two channels without a layout cannot be expressed.
        #expect(throws: PlaybackError.self) {
            _ = try FFmpegAudioDecoder.pcmFormat(sampleRate: 48_000, channelCount: 6, channelLayoutTag: 0)
        }
    }

    /// DFF chunk sizes are file-controlled 64-bit values; sizes near
    /// `UInt64.max` used to trap in unchecked additions during import.
    @Test(arguments: [UInt64.max, UInt64.max - 1])
    func hugeDFFChunkSizesDoNotCrashTheDurationProbe(chunkSize: UInt64) throws {
        let directory = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        func bigEndian(_ value: UInt64) -> [UInt8] {
            (0..<8).map { UInt8((value >> UInt64((7 - $0) * 8)) & 0xFF) }
        }

        for chunkID in ["PROP", "DSD ", "JUNK"] {
            var bytes: [UInt8] = Array("FRM8".utf8) + bigEndian(64) + Array("DSD ".utf8)
            bytes += Array(chunkID.utf8) + bigEndian(chunkSize)
            bytes += Array("SND ".utf8) + Array("FS  ".utf8) + bigEndian(chunkSize)
            bytes += [UInt8](repeating: 0, count: 32)
            let url = directory.appendingPathComponent("crafted-\(chunkID.trimmingCharacters(in: .whitespaces)).dff")
            try Data(bytes).write(to: url)

            // Reaching the expectation at all is the point; a crafted header
            // must not produce a usable duration either.
            let duration = AudioFileDurationProbe.duration(for: url)
            #expect(duration == nil || (duration ?? 0) < 1)
        }
    }
}

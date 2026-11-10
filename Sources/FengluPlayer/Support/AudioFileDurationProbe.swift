import AudioToolbox
import FengluFFmpeg
import Foundation

enum AudioFileDurationProbe {
    static func duration(for url: URL) -> TimeInterval? {
        guard url.isFileURL else {
            return nil
        }

        switch url.pathExtension.localizedLowercase {
        case "dff":
            return dffDuration(for: url) ?? audioToolboxDuration(for: url) ?? ffmpegDuration(for: url)
        case "dsf":
            return dsfDuration(for: url) ?? audioToolboxDuration(for: url) ?? ffmpegDuration(for: url)
        default:
            return audioToolboxDuration(for: url) ?? ffmpegDuration(for: url)
        }
    }

    private static func audioToolboxDuration(for url: URL) -> TimeInterval? {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else {
            return nil
        }
        defer {
            AudioFileClose(audioFile)
        }

        var duration = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let propertyStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyEstimatedDuration,
            &size,
            &duration
        )
        guard propertyStatus == noErr, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }

    private static func ffmpegDuration(for url: URL) -> TimeInterval? {
        var duration = Double(0)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = errorBuffer.withUnsafeMutableBufferPointer { errorPointer -> Int32 in
            url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
                guard let fileSystemPath, let errorBaseAddress = errorPointer.baseAddress else {
                    return -1
                }

                return fl_ffmpeg_probe_duration(
                    fileSystemPath,
                    &duration,
                    errorBaseAddress,
                    Int32(errorPointer.count)
                )
            }
        }

        guard result == 0, duration.isFinite, duration > 0 else {
            let message = errorBuffer.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else {
                    return "unknown error"
                }
                return String(cString: baseAddress).nonEmpty ?? "unknown error"
            }
            DebugLog.log(
                "Audio duration FFmpeg probe failed: file='\(url.lastPathComponent)' error='\(message)'"
            )
            return nil
        }

        return duration
    }

    private static func dsfDuration(for url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 256),
              data.count >= 80,
              data.asciiString(at: 0, length: 4) == "DSD ",
              let fmtOffset = data.firstChunkOffset(named: "fmt "),
              let sampleRate = data.uint32LittleEndian(at: fmtOffset + 28),
              let sampleCount = data.uint64LittleEndian(at: fmtOffset + 36),
              sampleRate > 0,
              sampleCount > 0
        else {
            return nil
        }

        return Double(sampleCount) / Double(sampleRate)
    }

    private static func dffDuration(for url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd(),
              let header = readData(from: handle, at: 0, count: 16),
              header.count == 16,
              header.asciiString(at: 0, length: 4) == "FRM8",
              header.asciiString(at: 12, length: 4) == "DSD "
        else {
            return nil
        }

        var offset: UInt64 = 16
        var sampleRate: UInt32?
        var channelCount: UInt16?
        var dsdByteCount: UInt64?

        while offset + 12 <= fileSize {
            guard let chunkHeader = readData(from: handle, at: offset, count: 12),
                  chunkHeader.count == 12,
                  let chunkID = chunkHeader.asciiString(at: 0, length: 4),
                  let chunkSize = chunkHeader.uint64BigEndian(at: 4)
            else {
                break
            }

            let dataOffset = offset + 12
            if chunkID == "PROP" {
                let properties = dffSoundProperties(
                    from: handle,
                    dataOffset: dataOffset,
                    chunkSize: chunkSize,
                    fileSize: fileSize
                )
                sampleRate = sampleRate ?? properties.sampleRate
                channelCount = channelCount ?? properties.channelCount
            } else if chunkID == "DSD " {
                // A declared size larger than the file would report an absurd
                // duration; the audio cannot be longer than the bytes present.
                dsdByteCount = min(chunkSize, fileSize - dataOffset)
            }

            guard let nextOffset = nextDFFChunkOffset(dataOffset: dataOffset, chunkSize: chunkSize, fileSize: fileSize),
                  nextOffset > offset
            else {
                break
            }
            offset = nextOffset
        }

        guard let sampleRate,
              let channelCount,
              let dsdByteCount,
              sampleRate > 0,
              channelCount > 0,
              dsdByteCount > 0
        else {
            return nil
        }

        return (Double(dsdByteCount) * 8.0) / (Double(sampleRate) * Double(channelCount))
    }

    private static func dffSoundProperties(
        from handle: FileHandle,
        dataOffset: UInt64,
        chunkSize: UInt64,
        fileSize: UInt64
    ) -> (sampleRate: UInt32?, channelCount: UInt16?) {
        guard chunkSize >= 4,
              dataOffset <= fileSize,
              fileSize - dataOffset >= 4,
              let propertyType = readData(from: handle, at: dataOffset, count: 4)?.asciiString(at: 0, length: 4),
              propertyType == "SND "
        else {
            return (nil, nil)
        }

        // chunkSize comes straight from the file; never add it unchecked.
        let propertiesEnd = chunkSize <= fileSize - dataOffset ? dataOffset + chunkSize : fileSize
        var offset = dataOffset + 4
        var sampleRate: UInt32?
        var channelCount: UInt16?

        while offset + 12 <= propertiesEnd {
            guard let chunkHeader = readData(from: handle, at: offset, count: 12),
                  chunkHeader.count == 12,
                  let chunkID = chunkHeader.asciiString(at: 0, length: 4),
                  let subchunkSize = chunkHeader.uint64BigEndian(at: 4)
            else {
                break
            }

            let subchunkDataOffset = offset + 12
            switch chunkID.trimmingCharacters(in: .whitespaces) {
            case "FS":
                if let data = readData(from: handle, at: subchunkDataOffset, count: 4),
                   let value = data.uint32BigEndian(at: 0) {
                    sampleRate = value
                }
            case "CHNL":
                if let data = readData(from: handle, at: subchunkDataOffset, count: 2),
                   let value = data.uint16BigEndian(at: 0) {
                    channelCount = value
                }
            default:
                break
            }

            guard let nextOffset = nextDFFChunkOffset(
                dataOffset: subchunkDataOffset,
                chunkSize: subchunkSize,
                fileSize: propertiesEnd
            ),
                  nextOffset > offset
            else {
                break
            }
            offset = nextOffset
        }

        return (sampleRate, channelCount)
    }

    private static func readData(from handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0 else {
            return nil
        }

        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private static func nextDFFChunkOffset(dataOffset: UInt64, chunkSize: UInt64, fileSize: UInt64) -> UInt64? {
        // chunkSize is file-controlled; UInt64.max + 1 would trap.
        let (paddedSize, overflowed) = chunkSize.addingReportingOverflow(chunkSize.isMultiple(of: 2) ? 0 : 1)
        guard !overflowed,
              dataOffset <= fileSize,
              paddedSize <= fileSize - dataOffset
        else {
            return nil
        }

        return dataOffset + paddedSize
    }
}

private extension Data {
    func asciiString(at offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= count else {
            return nil
        }

        return String(bytes: self[offset..<offset + length], encoding: .ascii)
    }

    func firstChunkOffset(named chunkName: String) -> Int? {
        guard let chunkData = chunkName.data(using: .ascii), chunkData.count == 4, count >= 4 else {
            return nil
        }

        let upperBound = count - chunkData.count
        for offset in 0...upperBound where self[offset..<offset + chunkData.count].elementsEqual(chunkData) {
            return offset
        }

        return nil
    }

    func uint32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    func uint64LittleEndian(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else {
            return nil
        }

        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    func uint16BigEndian(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else {
            return nil
        }

        return (UInt16(self[offset]) << 8) |
            UInt16(self[offset + 1])
    }

    func uint32BigEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        return (UInt32(self[offset]) << 24) |
            (UInt32(self[offset + 1]) << 16) |
            (UInt32(self[offset + 2]) << 8) |
            UInt32(self[offset + 3])
    }

    func uint64BigEndian(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else {
            return nil
        }

        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[offset + index])
        }
        return value
    }
}

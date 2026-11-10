import CoreAudio
import Dispatch
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
}

/// Observes changes to the Core Audio device list and the system's default
/// output device. Core Audio delivers these callbacks on the main queue so the
/// playback controller can update its published state immediately.
final class AudioOutputDeviceMonitor {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private let handler: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = []

    init(onChange: @escaping @MainActor () -> Void) {
        handler = { _, _ in
            MainActor.assumeIsolated {
                onChange()
            }
        }

        start()
    }

    deinit {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, queue, handler)
        }
    }

    private func start() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &address,
                queue,
                handler
            )
            if status == noErr {
                addresses.append(address)
            } else {
                DebugLog.log("Could not monitor audio devices (Core Audio status \(status))")
            }
        }
    }
}

enum AudioOutputDeviceDiscovery {
    static func devices() -> [AudioOutputDevice] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs()
            .filter { isOutputDevice($0) && isAlive($0) && !isHidden($0) }
            .compactMap { deviceID -> AudioOutputDevice? in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) else {
                    return nil
                }

                let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Output \(deviceID)"
                return AudioOutputDevice(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    isDefault: defaultID == deviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(-1)
            }

            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }

        guard status == noErr else {
            return []
        }

        return deviceIDs
    }

    private static func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &size
        )

        return status == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        integerProperty(kAudioDevicePropertyDeviceIsAlive, for: deviceID).map { $0 != 0 } ?? true
    }

    private static func isHidden(_ deviceID: AudioDeviceID) -> Bool {
        integerProperty(kAudioDevicePropertyIsHidden, for: deviceID).map { $0 != 0 } ?? false
    }

    private static func integerProperty(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }

        guard status == noErr, let value else {
            return nil
        }

        return value as String
    }
}

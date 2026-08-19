import CoreAudio
import Foundation
import HoloCore

enum SystemAudioRouteError: Error, LocalizedError {
    case propertyReadFailed(selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .propertyReadFailed(_, let status):
            return "Core Audio could not inspect the current audio route (error \(status))."
        }
    }
}

enum SystemAudioRouteInspector {
    static func currentRoute() throws -> AudioRouteInfo {
        let input = try endpoint(forDefaultDevice: kAudioHardwarePropertyDefaultInputDevice)
        let output = try? endpoint(forDefaultDevice: kAudioHardwarePropertyDefaultOutputDevice)
        return AudioRouteInfo(input: input, output: output)
    }

    /// The current default input device, or nil when Core Audio has none.
    /// Non-throwing on purpose: callers use this for opportunistic checks where
    /// "cannot tell" and "no device" must behave the same.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// True when some process has the device's input stream running. It counts
    /// our own engine too, so it is only conclusive while Holo is not capturing.
    static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    private static func endpoint(
        forDefaultDevice selector: AudioObjectPropertySelector
    ) throws -> AudioEndpointInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        guard status == noErr else {
            throw SystemAudioRouteError.propertyReadFailed(selector: selector, status: status)
        }
        guard deviceID != kAudioObjectUnknown else { return nil }

        let name = (try? deviceName(deviceID)) ?? "Unknown audio device"
        let transport = try transportType(deviceID)
        return AudioEndpointInfo(
            name: name,
            isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
        )
    }

    private static func deviceName(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedName
        )
        guard status == noErr else {
            throw SystemAudioRouteError.propertyReadFailed(
                selector: kAudioObjectPropertyName,
                status: status
            )
        }
        return (unmanagedName?.takeUnretainedValue() as String?) ?? "Unknown audio device"
    }

    private static func transportType(_ deviceID: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else {
            throw SystemAudioRouteError.propertyReadFailed(
                selector: kAudioDevicePropertyTransportType,
                status: status
            )
        }
        return transport
    }
}

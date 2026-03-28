import AudioToolbox
import CoreFoundation
import Foundation

// MARK: - AudioObjectID basics

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return value
    }

    func readBool(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> Bool {
        let value: UInt32 = try read(selector, scope: scope, defaultValue: 0)
        return value != 0
    }

    func readString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        var cfString: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &cfString)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return cfString as String
    }

    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        let count = Int(size) / MemoryLayout<T>.size
        var items = [T](repeating: defaultValue, count: count)
        err = items.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return items
    }
}

extension AudioObjectID {
    static func readDeviceList() throws -> [AudioDeviceID] {
        try AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices,
            defaultValue: AudioDeviceID.unknown
        )
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            defaultValue: AudioObjectID.unknown
        )
    }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }

    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    func waitUntilReady(timeout: TimeInterval = 2.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() { return true }
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }
        return false
    }
}

// MARK: - Device

typealias AudioDeviceID = AudioObjectID

extension AudioDeviceID {
    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48_000))
    }

    private func readStreams(scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &streams)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return streams
    }

    func firstOutputStreamIndex() throws -> UInt {
        let globalStreams = try readStreams(scope: kAudioObjectPropertyScopeGlobal)
        for (index, streamID) in globalStreams.enumerated() {
            let direction: UInt32 = try streamID.read(kAudioStreamPropertyDirection, defaultValue: 0)
            if direction == 0 { return UInt(index) }
        }
        let outputStreams = try readStreams(scope: kAudioObjectPropertyScopeOutput)
        if !outputStreams.isEmpty { return 0 }
        throw NSError(domain: "tonepose", code: -1, userInfo: [NSLocalizedDescriptionKey: "No output stream"])
    }

    func preferredStereoChannelIndices() -> (left: Int, right: Int) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &channels)
        guard err == noErr, channels.count >= 2 else { return (0, 1) }
        let left = Swift.max(0, Int(channels[0]) - 1)
        let right = Swift.max(0, Int(channels[1]) - 1)
        return (left, right)
    }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }
}

import CoreAudio

struct AudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String { "\(operation) failed (\(status))" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioError(operation: operation, status: status) }
}

/// Thin typed accessors over the Core Audio property API.
enum AudioSystem {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read '\(fourCC(selector))'")
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read '\(fourCC(selector))'")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static var defaultOutputDevice: AudioObjectID {
        get throws { try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)) }
    }

    /// The Core Audio process object for this app, so the tap can leave our own output alone.
    static var ownProcessObject: AudioObjectID {
        get throws {
            var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid()
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                "translate pid"
            )
            return object
        }
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size '\(fourCC(selector))'")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!), "read '\(fourCC(selector))'")
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        try? read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// Every process Core Audio is tracking, i.e. every process that has touched audio.
    static func processes() -> [AudioProcess] {
        let objects = (try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objects.compactMap { object in
            guard let pid = try? read(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundleID = (try? readString(object, kAudioProcessPropertyBundleID)) ?? ""
            let playing = ((try? read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            return AudioProcess(object: object, pid: pid, bundleID: bundleID, isPlaying: playing)
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(value)"
    }
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
}

/// Owns one Core Audio property listener, delivered on the main queue, until `invalidate()`.
@MainActor final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor () -> Void
    ) {
        self.object = object
        address = AudioSystem.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            self.block = block
        }
    }

    func invalidate() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        self.block = nil
    }
}
extension AudioSystem {
    /// Whether any client is doing IO on `device`, i.e. whether its IO procs should be firing.
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        ((try? read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))) ?? 0) != 0
    }
}

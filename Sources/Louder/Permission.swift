import Foundation

/// The "System Audio Recording" privacy permission a process tap needs.
///
/// There's no public API to ask about it. Without it, Core Audio still creates the tap and,
/// because we mute what we tap, the user hears nothing at all. So check up front through
/// TCC, the framework behind every privacy prompt, loaded dynamically. If it's missing or
/// changes shape, the status is `.unknown` and we proceed as before.
enum AudioCapturePermission {
    case granted, denied, unknown

    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: AudioCapturePermission {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Calls back on the main queue.
    static func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

import AppKit
import LouderCore

/// An app as the per-app menu shows it: helper processes folded into the app they serve.
struct AudioApp {
    let bundleID: String
    let name: String
    let isPlaying: Bool
}

@MainActor enum AudioApps {
    /// Private but long-stable libsystem call that maps an XPC helper (Chrome's renderers,
    /// Safari's WebKit GPU process) to the app it works for. Looked up dynamically.
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        if let responsible, case let owner = responsible(pid), owner > 0, owner != pid,
           let app = NSRunningApplication(processIdentifier: owner) {
            return app
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Every audio process, tagged with its owning app, for building the tap's bundle ID list.
    static func clients() -> [AudioClient] {
        AudioSystem.processes().compactMap { process in
            guard !process.bundleID.isEmpty, process.pid != getpid() else { return nil }
            return AudioClient(bundleID: process.bundleID, appBundleID: owningApp(of: process.pid)?.bundleIdentifier)
        }
    }

    /// Regular (Dock) apps that have opened audio, playing ones first, plus any `selected`
    /// apps that aren't running, so they can still be unticked.
    static func list(including selected: Set<String>) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for process in AudioSystem.processes() where process.pid != getpid() {
            guard let app = owningApp(of: process.pid), app.activationPolicy == .regular,
                  let id = app.bundleIdentifier else { continue }
            let playing = process.isPlaying || (apps[id]?.isPlaying ?? false)
            apps[id] = AudioApp(bundleID: id, name: app.localizedName ?? id, isPlaying: playing)
        }
        for id in selected where apps[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            apps[id] = AudioApp(bundleID: id, name: name, isPlaying: false)
        }
        return apps.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

import AppKit
import CoreAudio
import LouderCore
import os
import Synchronization

/// Routes system audio (or chosen apps' audio) through a gain stage on its way to the
/// current output device.
///
/// A process tap captures what the tapped apps are playing and mutes the original while we
/// read it. A private aggregate device pairs that tap with the real output device, and its IO
/// proc writes the boosted tap audio to the output. If Louder dies, the tap goes away with it
/// and the system plays normally again.
///
/// The engine keeps `isEnabled` (what the user wants) separate from `isRunning` (what's
/// actually happening). Whenever they disagree, `problem` says why. Device changes, format
/// changes, sleep and stalls rebuild the pipeline whenever the user wants it on.
@MainActor final class BoostEngine {
    enum Problem: Equatable {
        /// The user denied System Audio Recording.
        case permissionDenied
        /// Waiting on the permission prompt.
        case awaitingPermission
        case failed(String)
    }

    private let state = RenderState()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var tapBundleIDs: [String] = []
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.andreiz.louder.io", qos: .userInteractive)

    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var restartWork: DispatchWorkItem?
    private var watchdog = Watchdog()
    private var watchdogTimer: Timer?
    private var asleep = false
    private var askedForPermission = false

    private(set) var isEnabled = false
    private(set) var isRunning = false
    private(set) var problem: Problem?
    private(set) var outputName = ""
    /// Called whenever any of the above changes.
    var onChange: (() -> Void)?

    var gain: Float {
        get { state.target }
        set { state.target = min(max(newValue, Booster.minimumGain), Booster.maximumGain) }
    }

    /// Bundle IDs of the apps to boost; empty boosts everything.
    var boostedApps: Set<String> = [] {
        didSet { if boostedApps != oldValue { retarget() } }
    }

    init() {
        refreshOutputName()
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners = [
            PropertyListener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.refreshOutputName()
                self?.scheduleRestart("default output changed")
            },
            PropertyListener(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
                // New helper processes (a browser tab starting to play) may belong to a boosted app.
                if self?.boostedApps.isEmpty == false { self?.retarget() }
            },
        ]
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    // MARK: - Control

    func setEnabled(_ on: Bool) {
        isEnabled = on
        watchdog.reset()
        problem = nil
        if on { start() } else { stop() }
        onChange?()
    }

    private func start() {
        guard isEnabled, !isRunning, !asleep else { return }
        switch AudioCapturePermission.status {
        case .denied:
            problem = .permissionDenied
            return
        case .unknown where !askedForPermission:
            askedForPermission = true
            problem = .awaitingPermission
            AudioCapturePermission.request { [weak self] granted in
                guard let self, self.isEnabled, self.problem == .awaitingPermission else { return }
                self.problem = granted ? nil : .permissionDenied
                if granted { self.start() }
                self.onChange?()
            }
            return
        case .unknown, .granted:
            // Still unknown after asking means TCC can't tell us; try, as before.
            break
        }
        do {
            try build()
            isRunning = true
            problem = nil
            watchdog.engineStarted()
            startWatchdog()
            Logger.louder.info("Started on \(self.outputName, privacy: .public)")
        } catch {
            tearDown()
            problem = .failed(String(describing: error))
            Logger.louder.error("Start failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        guard isRunning else { return }
        tearDown()
        isRunning = false
    }

    private func restart(_ reason: String) {
        restartWork = nil
        guard isEnabled else { return }
        Logger.louder.info("Restarting: \(reason, privacy: .public)")
        stop()
        start()
        onChange?()
    }

    /// Collapses bursts of device notifications (unplugging a dock fires several) into one rebuild.
    private func scheduleRestart(_ reason: String, after delay: TimeInterval = 0.3) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restart(reason) } }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        onChange?()
    }

    private func willSleep() {
        asleep = true
        restartWork?.cancel()
        stop()
    }

    private func didWake() {
        asleep = false
        // Give the audio hardware a moment to come back before rebuilding.
        scheduleRestart("woke from sleep", after: 1.5)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchdog() }
        }
    }

    private func checkWatchdog() {
        guard isRunning else { return }
        // Core Audio idles the aggregate while nothing tapped is playing; that's not a stall.
        guard AudioSystem.isRunningSomewhere(aggregate) else {
            watchdog.engineStarted()
            return
        }
        switch watchdog.check(callbacks: state.callbacks.load(ordering: .relaxed)) {
        case .healthy:
            break
        case .restart:
            restart("audio stopped flowing")
        case .giveUp:
            stop()
            problem = .failed("The output device stopped responding")
            Logger.louder.error("Giving up after repeated stalls")
            onChange?()
        }
    }

    // MARK: - Pipeline

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        if boostedApps.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try AudioSystem.ownProcessObject])
            tapBundleIDs = []
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: [])
            tapBundleIDs = AppSelection.tapBundleIDs(selected: boostedApps, clients: AudioApps.clients())
            description.bundleIDs = tapBundleIDs
            // Keep tapping an app across quits and relaunches.
            description.isProcessRestoreEnabled = true
        }
        description.uuid = tapUUID
        description.name = "Louder"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    /// Points the running tap at the current app selection without rebuilding the aggregate,
    /// so audio from apps already being boosted doesn't drop out.
    private func retarget() {
        guard isRunning else { return }
        let wanted = boostedApps.isEmpty ? [] : AppSelection.tapBundleIDs(selected: boostedApps, clients: AudioApps.clients())
        if wanted == tapBundleIDs { return }   // both empty: already tapping everything
        do {
            var description = try makeTapDescription()
            var address = AudioSystem.address(kAudioTapPropertyDescription)
            try withUnsafeMutablePointer(to: &description) {
                try check(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0), "retarget tap")
            }
        } catch {
            Logger.louder.error("\(String(describing: error), privacy: .public); rebuilding instead")
            restart("app selection changed")
        }
    }

    private func build() throws {
        let output = try AudioSystem.defaultOutputDevice
        let outputUID = try AudioSystem.readString(output, kAudioDevicePropertyDeviceUID)
        outputName = (try? AudioSystem.readString(output, kAudioObjectPropertyName)) ?? ""

        tapUUID = UUID()
        let description = try makeTapDescription()
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Louder",
            kAudioAggregateDeviceUIDKey: "com.andreiz.louder.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create aggregate device")

        // Not running yet, so it's safe to size the limiter for this device's rate.
        state.booster.prepare(sampleRate: AudioSystem.nominalSampleRate(aggregate) ?? 48_000)
        state.current = state.target
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue, Self.makeIOBlock(state)), "create IO proc")
        useOnlyTapInput()

        // Formats change under a running device (AirPods switching profile, a new rate in
        // Audio MIDI Setup) without the default device changing; rebuild for those too.
        deviceListeners = [
            PropertyListener(output, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.scheduleRestart("output device went away") },
            PropertyListener(output, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.scheduleRestart("sample rate changed") },
            PropertyListener(output, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                self?.scheduleRestart("channel layout changed")
            },
        ]
        try check(AudioDeviceStart(aggregate, ioProc), "start audio")
    }

    /// Built outside the main actor: the block runs on the real-time IO thread, and a
    /// closure formed inside a @MainActor method would assert it's on the main thread.
    nonisolated private static func makeIOBlock(_ state: RenderState) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            // The tap's stream comes after the output device's own input streams (e.g. a headset mic).
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            let target = state.target
            state.booster.render(source: inputs.last, into: outputs, from: state.current, to: target)
            state.current = target
            state.callbacks.add(1, ordering: .relaxed)
        }
    }

    /// Turns off the output device's own input streams for our IO proc, so boosting AirPods
    /// doesn't open their microphone (which would drop them into low-quality headset mode).
    private func useOnlyTapInput() {
        guard let ioProc else { return }
        let count = AudioSystem.streamCount(aggregate, scope: kAudioObjectPropertyScopeInput)
        guard count > 1 else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (count - 1) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = raw.advanced(by: MemoryLayout.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!)
            .bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = i == count - 1 ? 1 : 0 }
        var address = AudioSystem.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), raw)
        if status != noErr { Logger.louder.error("Couldn't limit input streams (\(status))") }
    }

    private func tearDown() {
        deviceListeners.forEach { $0.invalidate() }
        deviceListeners = []
        if aggregate != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        tapBundleIDs = []
    }

    private func refreshOutputName() {
        guard let device = try? AudioSystem.defaultOutputDevice else { return }
        outputName = (try? AudioSystem.readString(device, kAudioObjectPropertyName)) ?? ""
    }
}

/// Shared between the main thread (which sets `target`) and the audio thread (which ramps
/// `current` toward it). Only the audio thread touches `current` and `booster` while running;
/// the main thread touches them only while the IO proc is stopped.
private final class RenderState: @unchecked Sendable {
    private let targetBits = Atomic<UInt32>(Float(1).bitPattern)
    let callbacks = Atomic<UInt64>(0)
    var current: Float = 1
    /// Owns preallocated scratch memory, so the audio thread never allocates.
    let booster = Booster()

    var target: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

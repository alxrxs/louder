import AppKit
import LouderCore
import os
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = BoostEngine()
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let toggleRow = ToggleRow(title: "Louder")
    private let levelRow = LevelRow()
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fixItem = NSMenuItem(title: "", action: #selector(fixProblem), keyEquivalent: "")
    private let appsHeader = NSMenuItem.sectionHeader(title: "Apps")
    private let allAppsRow = CheckRow(title: "All Apps")
    private lazy var allAppsItem = viewItem(allAppsRow)
    /// Bundle ID → row, so ticking an app updates the open menu in place.
    private var appRows: [(id: String, row: CheckRow, item: NSMenuItem)] = []
    private let deviceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var signalSources: [DispatchSourceSignal] = []
    private var flashWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        stopCleanlyOnSignals()

        engine.gain = Preferences.gain
        engine.boostedApps = Preferences.boostedApps
        engine.onChange = { [weak self] in self?.refresh() }
        toggleRow.onToggle = { [weak self] on in self?.setEnabled(on) }
        levelRow.onChange = { [weak self] gain in self?.setGain(gain, flash: false) }

        hotKeys.register(HotKeys.toggle) { [weak self] in
            guard let self else { return }
            self.setEnabled(!self.engine.isEnabled)
        }
        hotKeys.register(HotKeys.louder) { [weak self] in self?.step(1) }
        hotKeys.register(HotKeys.quieter) { [weak self] in self?.step(-1) }

        setEnabled(Preferences.enabled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.setEnabled(false)
    }

    // MARK: - State

    private func setEnabled(_ on: Bool) {
        Preferences.enabled = on
        engine.setEnabled(on)
    }

    private func setGain(_ gain: Float, flash: Bool) {
        engine.gain = gain
        Preferences.gain = gain
        if flash { flashLevel() }
        refresh()
    }

    private func step(_ steps: Int) {
        setGain(Level.step(engine.gain, by: steps), flash: true)
    }

    private func refresh() {
        toggleRow.isOn = engine.isEnabled
        levelRow.update(gain: engine.gain, enabled: engine.isRunning)
        deviceItem.title = engine.outputName.isEmpty ? "No Output Device" : engine.outputName

        problemItem.isHidden = true
        fixItem.isHidden = true
        if engine.isEnabled, let problem = engine.problem {
            problemItem.isHidden = false
            fixItem.isHidden = false
            switch problem {
            case .permissionDenied:
                problemItem.title = "Needs System Audio Recording access"
                fixItem.title = "Open Privacy & Security…"
            case .awaitingPermission:
                problemItem.title = "Waiting for permission…"
                fixItem.isHidden = true
            case .failed(let message):
                problemItem.title = "Couldn’t start: \(message)"
                fixItem.title = "Try Again"
            }
        }

        // Its own glyph (not the system Sound menu's speaker), filled while boosting,
        // dimmed when on but not actually running.
        let button = statusItem.button
        button?.image = NSImage(
            systemSymbolName: engine.isEnabled ? "speaker.plus.fill" : "speaker.plus",
            accessibilityDescription: "Louder"
        )
        button?.appearsDisabled = engine.isEnabled && !engine.isRunning
    }

    /// Shows the new level next to the icon for a moment after a hotkey, since the menu's closed.
    private func flashLevel() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.title = LevelRow.format(engine.gain)
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.statusItem.button?.title = ""
                self?.statusItem.button?.imagePosition = .imageOnly
                self?.statusItem.length = NSStatusItem.squareLength
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Menu bar

    /// A stock menu, laid out like the system's Sound menu: custom rows only where a stock
    /// item can't express the control (the switch and the slider).
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Not `statusItem.menu`, so a click can be intercepted: ⌥-click toggles instead.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem.button?.toolTip = "Louder: ⌥-click or \(HotKeys.toggle.display) to toggle, \(HotKeys.louder.display) \(HotKeys.quieter.display) to adjust"

        menu.delegate = self
        menu.minimumWidth = MenuMetrics.width
        menu.addItem(viewItem(toggleRow))
        menu.addItem(viewItem(levelRow))
        problemItem.isEnabled = false
        problemItem.isHidden = true
        menu.addItem(problemItem)
        fixItem.target = self
        fixItem.isHidden = true
        menu.addItem(fixItem)
        menu.addItem(.separator())
        menu.addItem(appsHeader)
        allAppsRow.onClick = { [weak self] in self?.setBoostedApps([]) }
        menu.addItem(allAppsItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Output"))
        deviceItem.isEnabled = false
        deviceItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        menu.addItem(deviceItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        let soundSettings = NSMenuItem(title: "Sound Settings…", action: #selector(openSoundSettings), keyEquivalent: "")
        soundSettings.target = self
        menu.addItem(soundSettings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Louder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.modifierFlags.contains(.option) {
            setEnabled(!engine.isEnabled)
            return
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
        rebuildAppItems()
        refresh()
    }

    // MARK: - Apps

    /// Rows are custom views, so clicking one toggles it and leaves the menu open for the next.
    private func rebuildAppItems() {
        appRows.forEach { menu.removeItem($0.item) }
        let index = menu.index(of: allAppsItem) + 1
        appRows = AudioApps.list(including: engine.boostedApps).map { app in
            let row = CheckRow(title: app.name, detail: app.isPlaying ? "Playing" : nil)
            row.onClick = { [weak self] in self?.toggleApp(app.bundleID) }
            return (app.bundleID, row, viewItem(row))
        }
        for (offset, entry) in appRows.enumerated() { menu.insertItem(entry.item, at: index + offset) }
        updateAppChecks()
    }

    private func updateAppChecks() {
        let selected = engine.boostedApps
        allAppsRow.isChecked = selected.isEmpty
        for entry in appRows { entry.row.isChecked = selected.contains(entry.id) }
    }

    private func toggleApp(_ id: String) {
        var apps = engine.boostedApps
        if apps.contains(id) { apps.remove(id) } else { apps.insert(id) }
        setBoostedApps(apps)
    }

    private func setBoostedApps(_ apps: Set<String>) {
        engine.boostedApps = apps
        Preferences.boostedApps = apps
        updateAppChecks()
    }

    // MARK: - Actions

    @objc private func fixProblem() {
        if engine.problem == .permissionDenied {
            NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
        } else {
            setEnabled(true)
        }
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Logger.louder.error("Launch at login change failed: \(error, privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change Launch at Login"
            NSApp.activate()
            alert.runModal()
        }
    }

    /// `kill`/logout must tear the tap down cleanly, so route signals through a normal quit.
    private func stopCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }
}

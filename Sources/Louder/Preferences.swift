import Foundation

/// The boost level, on/off state and app selection, persisted across launches.
/// Defaults: 200%, off, all apps.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var gain: Float {
        get { defaults.object(forKey: "gain") as? Float ?? 2 }
        set { defaults.set(newValue, forKey: "gain") }
    }

    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Bundle IDs of the apps to boost; empty means every app.
    static var boostedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "boostedApps") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "boostedApps") }
    }
}

/// A process that Core Audio knows about, reduced to what per-app boosting needs.
public struct AudioClient: Equatable, Sendable {
    /// The process's own bundle ID, e.g. `com.google.Chrome.helper`.
    public var bundleID: String
    /// The bundle ID of the app responsible for it, e.g. `com.google.Chrome`, if known.
    public var appBundleID: String?

    public init(bundleID: String, appBundleID: String?) {
        self.bundleID = bundleID
        self.appBundleID = appBundleID
    }
}

public enum AppSelection {
    /// The bundle IDs to tap so that boosting an app also boosts the helper processes that
    /// actually play its audio: Chrome's renderer helpers, Safari's WebKit GPU process, and
    /// so on. Sorted so callers can cheaply tell whether anything changed.
    public static func tapBundleIDs(selected: Set<String>, clients: [AudioClient]) -> [String] {
        var ids = selected
        for client in clients {
            if let app = client.appBundleID, selected.contains(app) {
                ids.insert(client.bundleID)
            } else if selected.contains(where: { client.bundleID.hasPrefix($0 + ".") }) {
                ids.insert(client.bundleID)
            }
        }
        return ids.sorted()
    }
}

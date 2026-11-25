import Foundation

/// Single source of truth for the app version and the start-up password.
enum AppInfo {
    /// Marketing version, mirrored into `CFBundleShortVersionString`.
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    /// Build number, mirrored into `CFBundleVersion`.
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"

    /// `1.1.0 (2)` — used in the window title and the lock dialog.
    static var displayVersion: String { "\(version) (\(build))" }

    /// Required to start the app.
    static let startupPassword = "0.30.30.3"
}

import Foundation

/// Timings and pixel counts are for debugging, not for everyday use: they show
/// only with `defaults write <bundle id> showTimings -bool YES`.
enum DeveloperInfo {
    static var showTimings: Bool { UserDefaults.standard.bool(forKey: AppSettings.Key.showTimings) }
}

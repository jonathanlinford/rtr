import Foundation

/// How Chromium profiles render in the picker.
enum ProfileDisplayMode: String, CaseIterable {
    /// One row per Chromium app, with a profile dropdown pill on the right.
    case grouped
    /// One row per profile (e.g., "Google Chrome — Personal", "Google Chrome — Work").
    case flat

    var menuLabel: String {
        switch self {
        case .grouped: return "Grouped (one row, pill)"
        case .flat:    return "Flat (one row per profile)"
        }
    }
}

/// User preferences not tied to routing rules. Stored in `UserDefaults`.
enum Settings {
    static let profileDisplayKey = "rtr.profileDisplayMode"
    static let profileDisplayDidChange = Notification.Name("rtr.profileDisplayDidChange")

    static var profileDisplay: ProfileDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: profileDisplayKey) ?? ""
            return ProfileDisplayMode(rawValue: raw) ?? .grouped
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: profileDisplayKey)
            NotificationCenter.default.post(name: profileDisplayDidChange, object: nil)
        }
    }
}

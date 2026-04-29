import AppKit

/// User's preferred app appearance, persisted across launches.
/// `system` (default) follows macOS Settings; `light`/`dark` force.
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var menuLabel: String {
        switch self {
        case .system: return "System Default"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` means "inherit from the system" — equivalent to clearing NSApp.appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// All semantic colors used by the picker / stats UI. Each is a dynamic
/// `NSColor` that resolves to the right RGBA at draw time based on the
/// effective appearance, so views just need to reapply their CGColors
/// when the appearance changes (see `viewDidChangeEffectiveAppearance`).
enum Theme {
    static let appearanceDidChange = Notification.Name("rtr.appearanceDidChange")
    static let storageKey = "rtr.appearance"

    static var mode: AppearanceMode {
        get {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            apply()
        }
    }

    /// Apply the current `mode` to NSApp and broadcast a notification so views
    /// that cache CGColors can refresh themselves immediately, even before
    /// AppKit's own `viewDidChangeEffectiveAppearance` fires.
    static func apply() {
        NSApp.appearance = mode.nsAppearance
        NotificationCenter.default.post(name: appearanceDidChange, object: nil)
    }

    // MARK: - Picker / HUD palette
    //
    // The picker is a translucent pop-up. In dark mode it reads as a near-black
    // HUD with white tints; in light mode as a near-white frosted card with
    // black tints.

    static let panelBackground = dynamic(
        light: NSColor(calibratedWhite: 0.98, alpha: 0.96),
        dark:  NSColor(calibratedWhite: 0.08, alpha: 0.96)
    )

    static let panelBorder = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.10)
    )

    static let primaryText = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 1.0),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 1.0)
    )

    static let secondaryText = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 0.60),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 0.60)
    )

    static let tertiaryText = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 0.45),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 0.50)
    )

    static let quaternaryText = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 0.35),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 0.40)
    )

    static let placeholderTint = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 0.55),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 0.55)
    )

    static let rowSelectedBackground = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.14)
    )

    static let rowHoverBackground = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.05),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.08)
    )

    // Pill / chip surfaces (profile dropdown, +Rule chip, etc.)
    static let pillBackground = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.06),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.09)
    )
    static let pillBackgroundHover = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.16)
    )
    static let pillBackgroundPressed = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.14),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.22)
    )
    static let pillBorder = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.10)
    )
    static let pillBorderHover = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.14),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.18)
    )
    static let pillLabel = dynamic(
        light: NSColor(calibratedWhite: 0.05, alpha: 0.85),
        dark:  NSColor(calibratedWhite: 1.00, alpha: 0.90)
    )

    // Rule form
    static let formBackground = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.04),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.04)
    )
    static let formBorder = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.08),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.08)
    )
    static let textFieldBackground = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.65),
        dark:  NSColor(calibratedWhite: 0.0, alpha: 0.35)
    )
    static let textFieldBorder = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.18),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.15)
    )

    // MARK: - Stats window palette

    static let statsBackground = dynamic(
        light: NSColor(calibratedWhite: 0.97, alpha: 1.0),
        dark:  NSColor(calibratedWhite: 0.10, alpha: 1.0)
    )

    static let statsCardBackground = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.05),
        dark:  NSColor(calibratedWhite: 1.0, alpha: 0.06)
    )

    // MARK: - Helpers

    /// Build a dynamic `NSColor` that resolves to one of two values based on
    /// the effective appearance at draw time.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return isDark ? dark : light
        }
    }
}

extension NSColor {
    /// CGColor resolved against `appearance` (or `NSApp.effectiveAppearance` if
    /// nil). Works around the fact that a dynamic `NSColor`'s `.cgColor`
    /// captures whatever appearance was current at the call site.
    func cgColor(for appearance: NSAppearance? = nil) -> CGColor {
        let app = appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        var out: CGColor = self.cgColor
        app.performAsCurrentDrawingAppearance {
            out = self.cgColor
        }
        return out
    }
}

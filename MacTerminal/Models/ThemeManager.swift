import SwiftUI
import Combine

enum Theme: String, CaseIterable {
    case dark = "dark"
    case gray = "gray"
    case light = "light"

    var label: String {
        switch self {
        case .dark:  return "Dark"
        case .gray:  return "Gray"
        case .light: return "Light"
        }
    }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    static let themeDidChangeNotification = Notification.Name("ThemeDidChange")

    @Published var current: Theme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "terminalTheme")
            rebuildColorCache()
            NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: nil)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "terminalTheme"),
           let theme = Theme(rawValue: raw) {
            current = theme
        } else {
            current = .dark
        }
        rebuildColorCache()
    }

    // Cached colors. Computed once per theme change rather than allocating
    // fresh NSColor instances on every property access. The terminal draw loop
    // hits these properties many times per frame; with cursor blink and PTY
    // updates, the resulting allocation churn is significant over time.
    private var _terminalBG: NSColor = .black
    private var _terminalFG: NSColor = .white
    private var _tabBarBG: NSColor = .black
    private var _tabItemHoverBG: NSColor = .clear
    private var _tabIconColor: NSColor = .white
    private var _tabTitleColor: NSColor = .white
    private var _tabCloseColor: NSColor = .white
    private var _findBarBG: NSColor = .black
    private var _statusBarBG: NSColor = .black
    private var _statusBarText: NSColor = .white
    private var _cursorColor: NSColor = .white
    private var _cursorTextColor: NSColor = .black
    private var _markedTextBG: NSColor = .blue
    private var _markedTextFG: NSColor = .white

    private func rebuildColorCache() {
        switch current {
        case .dark:
            _terminalBG  = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0)
            _terminalFG  = NSColor(red: 0.9,  green: 0.9,  blue: 0.9,  alpha: 1.0)
            _tabBarBG    = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
            _tabItemHoverBG = NSColor.white.withAlphaComponent(0.06)
            _tabIconColor   = .white
            _tabTitleColor  = .white
            _tabCloseColor  = NSColor.white.withAlphaComponent(0.4)
            _findBarBG      = NSColor(white: 0.15, alpha: 1)
            _statusBarBG    = NSColor(white: 0.08, alpha: 1)
            _statusBarText  = NSColor.white.withAlphaComponent(0.5)
            _cursorColor    = NSColor(white: 0.75, alpha: 1)
            _cursorTextColor = .black
            _markedTextBG   = NSColor(red: 0.2, green: 0.2, blue: 0.4, alpha: 1.0)
            _markedTextFG   = .white
        case .gray:
            _terminalBG  = NSColor(white: 0.30, alpha: 1.0)
            _terminalFG  = NSColor(white: 0.95, alpha: 1.0)
            _tabBarBG    = NSColor(white: 0.25, alpha: 1)
            _tabItemHoverBG = NSColor.white.withAlphaComponent(0.08)
            _tabIconColor   = .white
            _tabTitleColor  = .white
            _tabCloseColor  = NSColor.white.withAlphaComponent(0.4)
            _findBarBG      = NSColor(white: 0.35, alpha: 1)
            _statusBarBG    = NSColor(white: 0.22, alpha: 1)
            _statusBarText  = NSColor.white.withAlphaComponent(0.5)
            _cursorColor    = NSColor(white: 0.75, alpha: 1)
            _cursorTextColor = .black
            _markedTextBG   = NSColor(red: 0.35, green: 0.35, blue: 0.55, alpha: 1.0)
            _markedTextFG   = .white
        case .light:
            _terminalBG  = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            _terminalFG  = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
            _tabBarBG    = NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
            _tabItemHoverBG = NSColor.black.withAlphaComponent(0.06)
            _tabIconColor   = .black
            _tabTitleColor  = .black
            _tabCloseColor  = NSColor.black.withAlphaComponent(0.4)
            _findBarBG      = NSColor(white: 0.92, alpha: 1)
            _statusBarBG    = NSColor(white: 0.93, alpha: 1)
            _statusBarText  = NSColor.black.withAlphaComponent(0.5)
            _cursorColor    = NSColor(white: 0.25, alpha: 1)
            _cursorTextColor = .white
            _markedTextBG   = NSColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
            _markedTextFG   = .black
        }
    }

    var colorScheme: ColorScheme {
        current == .light ? .light : .dark
    }

    // MARK: - Terminal Colors

    var terminalBG: NSColor { _terminalBG }
    var terminalFG: NSColor { _terminalFG }

    // MARK: - Tab Bar Colors

    var tabBarBG: NSColor { _tabBarBG }
    var tabItemHoverBG: NSColor { _tabItemHoverBG }
    var tabIconColor: NSColor { _tabIconColor }
    var tabTitleColor: NSColor { _tabTitleColor }
    var tabCloseColor: NSColor { _tabCloseColor }

    // MARK: - Find Bar Colors

    var findBarBG: NSColor { _findBarBG }

    // MARK: - Status Bar Colors

    var statusBarBG: NSColor { _statusBarBG }
    var statusBarText: NSColor { _statusBarText }

    // MARK: - Cursor

    var cursorColor: NSColor { _cursorColor }
    var cursorTextColor: NSColor { _cursorTextColor }

    // MARK: - IME Marked Text

    var markedTextBG: NSColor { _markedTextBG }
    var markedTextFG: NSColor { _markedTextFG }
}

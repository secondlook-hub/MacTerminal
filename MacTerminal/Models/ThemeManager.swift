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
    }

    var colorScheme: ColorScheme {
        current == .light ? .light : .dark
    }

    // MARK: - Terminal Colors

    var terminalBG: NSColor {
        switch current {
        case .dark:  return NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0)
        case .gray:  return NSColor(white: 0.30, alpha: 1.0)
        case .light: return NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        }
    }

    var terminalFG: NSColor {
        switch current {
        case .dark:  return NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        case .gray:  return NSColor(white: 0.95, alpha: 1.0)
        case .light: return NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        }
    }

    // MARK: - Tab Bar Colors

    var tabBarBG: NSColor {
        switch current {
        case .dark:  return NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        case .gray:  return NSColor(white: 0.25, alpha: 1)
        case .light: return NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
        }
    }

    var tabItemHoverBG: NSColor {
        switch current {
        case .dark:  return NSColor.white.withAlphaComponent(0.06)
        case .gray:  return NSColor.white.withAlphaComponent(0.08)
        case .light: return NSColor.black.withAlphaComponent(0.06)
        }
    }

    var tabIconColor: NSColor {
        current == .light ? .black : .white
    }

    var tabTitleColor: NSColor {
        current == .light ? .black : .white
    }

    var tabCloseColor: NSColor {
        current == .light
            ? NSColor.black.withAlphaComponent(0.4)
            : NSColor.white.withAlphaComponent(0.4)
    }

    // MARK: - Find Bar Colors

    var findBarBG: NSColor {
        switch current {
        case .dark:  return NSColor(white: 0.15, alpha: 1)
        case .gray:  return NSColor(white: 0.35, alpha: 1)
        case .light: return NSColor(white: 0.92, alpha: 1)
        }
    }

    // MARK: - Status Bar Colors

    var statusBarBG: NSColor {
        switch current {
        case .dark:  return NSColor(white: 0.08, alpha: 1)
        case .gray:  return NSColor(white: 0.22, alpha: 1)
        case .light: return NSColor(white: 0.93, alpha: 1)
        }
    }

    var statusBarText: NSColor {
        current == .light
            ? NSColor.black.withAlphaComponent(0.5)
            : NSColor.white.withAlphaComponent(0.5)
    }

    // MARK: - Cursor

    var cursorColor: NSColor {
        current == .light
            ? NSColor(white: 0.25, alpha: 1)
            : NSColor(white: 0.75, alpha: 1)
    }

    var cursorTextColor: NSColor {
        current == .light ? .white : .black
    }

    // MARK: - IME Marked Text

    var markedTextBG: NSColor {
        switch current {
        case .dark:  return NSColor(red: 0.2, green: 0.2, blue: 0.4, alpha: 1.0)
        case .gray:  return NSColor(red: 0.35, green: 0.35, blue: 0.55, alpha: 1.0)
        case .light: return NSColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
        }
    }

    var markedTextFG: NSColor {
        current == .light ? .black : .white
    }
}

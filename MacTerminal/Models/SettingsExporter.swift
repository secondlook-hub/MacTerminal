import AppKit
import UniformTypeIdentifiers

struct ExportData: Codable {
    var version: Int = 1
    var connections: BookmarkTreeFile?
    var commands: [CommandItem]?
    var theme: String?
    var appearance: AppearanceSettings?
}

struct AppearanceSettings: Codable {
    var fontName: String?
    var fontSize: Double?
    var bgColor: CodableColor?
    var fgColor: CodableColor?
}

struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        red = Double(c.redComponent)
        green = Double(c.greenComponent)
        blue = Double(c.blueComponent)
        alpha = Double(c.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

enum SettingsExporter {

    static func exportSettings(
        bookmarkStore: SSHBookmarkStore,
        commandStore: CommandStore
    ) {
        let data = ExportData(
            version: 1,
            connections: BookmarkTreeFile(version: 2, rootItems: bookmarkStore.rootItems),
            commands: commandStore.commands,
            theme: ThemeManager.shared.current.rawValue,
            appearance: buildAppearance()
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "MacTerminal_Settings.json"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try encoder.encode(data)
                try json.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    static func importSettings(
        bookmarkStore: SSHBookmarkStore,
        commandStore: CommandStore
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let json = try Data(contentsOf: url)
                let data = try JSONDecoder().decode(ExportData.self, from: json)
                applySettings(data, bookmarkStore: bookmarkStore, commandStore: commandStore)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    // MARK: - Private

    private static func buildAppearance() -> AppearanceSettings {
        let ud = UserDefaults.standard
        var appearance = AppearanceSettings()
        appearance.fontName = ud.string(forKey: "terminalFontName")
        let size = ud.double(forKey: "terminalFontSize")
        if size > 0 { appearance.fontSize = size }

        if let bgData = ud.data(forKey: "terminalBGColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: bgData) {
            appearance.bgColor = CodableColor(color)
        }
        if let fgData = ud.data(forKey: "terminalFGColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fgData) {
            appearance.fgColor = CodableColor(color)
        }
        return appearance
    }

    private static func applySettings(
        _ data: ExportData,
        bookmarkStore: SSHBookmarkStore,
        commandStore: CommandStore
    ) {
        // Connections
        if let tree = data.connections {
            bookmarkStore.rootItems = tree.rootItems
            bookmarkStore.save()
        }

        // Commands
        if let cmds = data.commands {
            commandStore.commands = cmds
            commandStore.save()
        }

        // Theme
        if let raw = data.theme, let theme = Theme(rawValue: raw) {
            ThemeManager.shared.current = theme
        }

        // Appearance
        if let app = data.appearance {
            let ud = UserDefaults.standard
            if let name = app.fontName {
                ud.set(name, forKey: "terminalFontName")
            }
            if let size = app.fontSize {
                ud.set(size, forKey: "terminalFontSize")
            }
            if let bg = app.bgColor {
                if let archived = try? NSKeyedArchiver.archivedData(
                    withRootObject: bg.nsColor, requiringSecureCoding: true
                ) {
                    ud.set(archived, forKey: "terminalBGColor")
                }
            }
            if let fg = app.fgColor {
                if let archived = try? NSKeyedArchiver.archivedData(
                    withRootObject: fg.nsColor, requiringSecureCoding: true
                ) {
                    ud.set(archived, forKey: "terminalFGColor")
                }
            }
        }
    }
}

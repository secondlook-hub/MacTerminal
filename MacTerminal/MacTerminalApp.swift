import SwiftUI

@main
struct MacTerminalApp: App {
    @StateObject private var bookmarkStore = SSHBookmarkStore()
    @StateObject private var commandStore = CommandStore()
    @StateObject private var updateChecker = UpdateChecker()
    @ObservedObject private var themeManager = ThemeManager.shared
    @FocusedValue(\.terminalScreen) var focusedScreen
    @FocusedValue(\.terminalTab) var focusedTab
    @FocusedValue(\.isRecording) var isRecording
    @FocusedValue(\.tabManager) var focusedTabManager
    @AppStorage("blockSelectionMode") var blockSelectionMode = false
    @AppStorage("showLineNumber") var showLineNumber = false
    @AppStorage("showTimestamp") var showTimestamp = false

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Disable macOS "press and hold" accent popup so all keys repeat normally
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bookmarkStore)
                .environmentObject(commandStore)
                .environmentObject(updateChecker)
        }
        .defaultSize(width: 1100, height: 650)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Save Shell Content...") {
                    saveShellContent()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(focusedScreen == nil)

                Divider()

                Button("Start Recording...") {
                    startRecording()
                }
                .disabled(focusedTab == nil || isRecording == true)

                Button("Stop Recording") {
                    focusedTab?.stopRecording()
                }
                .disabled(isRecording != true)

                Divider()

                Menu("Settings") {
                    Button("Export...") {
                        SettingsExporter.exportSettings(
                            bookmarkStore: bookmarkStore,
                            commandStore: commandStore
                        )
                    }
                    Button("Import...") {
                        SettingsExporter.importSettings(
                            bookmarkStore: bookmarkStore,
                            commandStore: commandStore
                        )
                    }
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Toggle("Block Selection", isOn: $blockSelectionMode)
                Divider()
                Button("Find...") {
                    Self.findContainerView()?.toggleFindBar(show: true)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()

                Button("New Tab") {
                    focusedTabManager?.addLocalShellTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(focusedTabManager == nil)

                Button("Close Tab") {
                    if let tab = focusedTab, let manager = focusedTabManager {
                        manager.removeTab(tab.id)
                        if manager.tabs.isEmpty {
                            NSApp.keyWindow?.close()
                        }
                    } else {
                        NSApp.keyWindow?.close()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Check for Updates...") {
                    Task {
                        await updateChecker.checkForUpdates(manual: true)
                    }
                }
            }
            CommandGroup(before: .toolbar) {
                Button("Split View") {
                    focusedTab?.splitPane(axis: .horizontal)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(focusedTab == nil)

                Button("Close Split View") {
                    focusedTab?.closeSplit()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(focusedTab?.isSplit != true)

                Divider()
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Menu("Theme") {
                    ForEach(Theme.allCases, id: \.self) { theme in
                        Button {
                            ThemeManager.shared.current = theme
                        } label: {
                            if themeManager.current == theme {
                                Label(theme.label, systemImage: "checkmark")
                            } else {
                                Text(theme.label)
                            }
                        }
                    }
                }
                Toggle("Show Line Number", isOn: Binding(
                    get: { showLineNumber },
                    set: { newValue in
                        showLineNumber = newValue
                        Self.updateAllLineNumberVisibility(newValue)
                    }
                ))
                Toggle("Show Timestamp", isOn: Binding(
                    get: { showTimestamp },
                    set: { newValue in
                        showTimestamp = newValue
                        Self.updateAllTimestampVisibility(newValue)
                    }
                ))
                Divider()
                Button("Change Font...") {
                    Self.findDrawView()?.showFontPanel(nil)
                }
                Button("Background Color...") {
                    Self.findDrawView()?.showBGColorPanel(nil)
                }
                Button("Text Color...") {
                    Self.findDrawView()?.showFGColorPanel(nil)
                }
                Divider()
                Button("Reset to Default") {
                    Self.findDrawView()?.resetToDefaults(nil)
                }
            }
        }
    }

    private static func findDrawView() -> TerminalDrawView? {
        guard let view = NSApp.keyWindow?.contentView else { return nil }
        return findSubview(in: view)
    }

    private static func findContainerView() -> TerminalContainerView? {
        guard let view = NSApp.keyWindow?.contentView else { return nil }
        return findSubview(in: view)
    }

    private static func updateAllLineNumberVisibility(_ visible: Bool) {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            findAllSubviews(of: TerminalDrawView.self, in: contentView).forEach {
                $0.setLineNumberVisible(visible)
            }
        }
    }

    private static func updateAllTimestampVisibility(_ visible: Bool) {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            findAllSubviews(of: TerminalDrawView.self, in: contentView).forEach {
                $0.setTimestampVisible(visible)
            }
        }
    }

    private static func findAllSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let v = view as? T { result.append(v) }
        for sub in view.subviews { result.append(contentsOf: findAllSubviews(of: type, in: sub)) }
        return result
    }

    private static func findSubview<T: NSView>(in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews {
            if let found: T = findSubview(in: sub) { return found }
        }
        return nil
    }

    private func startRecording() {
        guard let tab = focusedTab, !tab.isRecording else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "terminal_recording.txt"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            tab.startRecording(url: url)
        }
    }

    private func saveShellContent() {
        guard let screen = focusedScreen else { return }
        let text = screen.extractText()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "terminal_output.txt"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

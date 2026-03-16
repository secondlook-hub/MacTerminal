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
    @AppStorage("textWrap") var textWrap = true
    @AppStorage("showDirectoryTree") var showDirectoryTree = false

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Disable macOS "press and hold" accent popup so all keys repeat normally
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
        // Trigger folder access permission prompts
        Self.requestFolderAccess()
        // Check Full Disk Access permission
        Self.checkFullDiskAccess()
    }

    private static func checkFullDiskAccess() {
        DispatchQueue.main.async {
            let testPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Bookmarks.plist")
            let hasAccess = FileManager.default.isReadableFile(atPath: testPath.path)

            if !hasAccess && !UserDefaults.standard.bool(forKey: "skipFullDiskAccessAlert") {
                let alert = NSAlert()
                alert.messageText = "전체 디스크 접근 권한 필요"
                alert.informativeText = """
                    MacTerminal이 정상적으로 동작하려면 '전체 디스크 접근 권한'이 필요합니다.

                    설정 방법:
                    1. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한
                    2. MacTerminal을 목록에서 찾아 활성화
                    3. 앱을 재시작

                    아래 버튼을 눌러 설정 화면을 열 수 있습니다.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "설정 열기")
                alert.addButton(withTitle: "나중에")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    UserDefaults.standard.set(true, forKey: "skipFullDiskAccessAlert")
                }
            }
        }
    }

    private static func requestFolderAccess() {
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        ]
        DispatchQueue.global(qos: .utility).async {
            for folder in folders {
                _ = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            }
        }
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
            CommandGroup(replacing: .appInfo) {
                Button("About MacTerminal") {
                    let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    let credits = NSMutableAttributedString(string: "https://miunsi.blogspot.com/", attributes: [
                        .link: URL(string: "https://miunsi.blogspot.com/")!,
                        .font: NSFont.systemFont(ofSize: 11)
                    ])
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .version: marketing,
                        .credits: credits
                    ])
                }
            }
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
                    .keyboardShortcut("b", modifiers: .command)
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
                Divider()
                Button("Visit Developer Website") {
                    if let url = URL(string: "https://miunsi.blogspot.com/") {
                        NSWorkspace.shared.open(url)
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
                Button("Input History") {
                    showInputHistory()
                }
                .keyboardShortcut("y", modifiers: .command)
                Divider()
                Toggle("Directory Tree", isOn: $showDirectoryTree)
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
                    get: { focusedTab?.showTimestamp ?? showTimestamp },
                    set: { newValue in
                        if let tab = focusedTab {
                            tab.showTimestamp = newValue
                        } else {
                            showTimestamp = newValue
                            Self.updateAllTimestampVisibility(newValue)
                        }
                    }
                ))
                Toggle("Text Wrap", isOn: Binding(
                    get: { textWrap },
                    set: { newValue in
                        textWrap = newValue
                        Self.updateAllTextWrap(newValue)
                    }
                ))
                Divider()
                Button("Text Bigger") {
                    Self.findDrawView()?.increaseFontSize(nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Text Smaller") {
                    Self.findDrawView()?.decreaseFontSize(nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Text Default Size") {
                    Self.findDrawView()?.resetFontSize(nil)
                }
                .keyboardShortcut("0", modifiers: .command)
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

    private static func updateAllTextWrap(_ enabled: Bool) {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            findAllSubviews(of: TerminalContainerView.self, in: contentView).forEach {
                $0.setTextWrap(enabled)
            }
        }
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

    private func showInputHistory() {
        InputHistoryPanel.show { command in
            guard let tab = focusedTab else { return }
            tab.terminal.write(command + "\r")
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

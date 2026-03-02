import SwiftUI

struct FocusedScreenKey: FocusedValueKey {
    typealias Value = TerminalScreen
}

struct FocusedTabKey: FocusedValueKey {
    typealias Value = TerminalTab
}

struct FocusedRecordingKey: FocusedValueKey {
    typealias Value = Bool
}

struct FocusedTabManagerKey: FocusedValueKey {
    typealias Value = TabManager
}

extension FocusedValues {
    var terminalScreen: TerminalScreen? {
        get { self[FocusedScreenKey.self] }
        set { self[FocusedScreenKey.self] = newValue }
    }
    var terminalTab: TerminalTab? {
        get { self[FocusedTabKey.self] }
        set { self[FocusedTabKey.self] = newValue }
    }
    var isRecording: Bool? {
        get { self[FocusedRecordingKey.self] }
        set { self[FocusedRecordingKey.self] = newValue }
    }
    var tabManager: TabManager? {
        get { self[FocusedTabManagerKey.self] }
        set { self[FocusedTabManagerKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var bookmarkStore: SSHBookmarkStore
    @EnvironmentObject var commandStore: CommandStore
    @StateObject private var tabManager = TabManager()
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var selectedItemID: UUID?
    @State private var showingAddSheet = false
    @State private var editingBookmark: SSHBookmark?
    @State private var targetFolderID: UUID?
    @State private var showingAddCommandSheet = false
    @State private var editingCommand: CommandItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedItemID: $selectedItemID,
                showingAddSheet: $showingAddSheet,
                editingBookmark: $editingBookmark,
                targetFolderID: $targetFolderID,
                showingAddCommandSheet: $showingAddCommandSheet,
                editingCommand: $editingCommand,
                onConnect: connectToHost,
                onRunCommand: runCommand
            )
        } detail: {
            VStack(spacing: 0) {
                TabBarView(tabManager: tabManager)
                if let tab = tabManager.selectedTab {
                    SplitTerminalView(nodeRef: tab.rootNode, tab: tab)
                        .id(tab.id)
                } else {
                    Color(nsColor: .terminalBG)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
        .focusedSceneValue(\.terminalScreen, tabManager.selectedTab?.screen)
        .focusedSceneValue(\.terminalTab, tabManager.selectedTab)
        .focusedSceneValue(\.isRecording, tabManager.selectedTab?.isRecording ?? false)
        .focusedSceneValue(\.tabManager, tabManager)
        .navigationTitle(tabManager.selectedTab?.windowTitle ?? "MacTerminal")
        .onAppear {
            DispatchQueue.main.async {
                WindowManager.shared.register(tabManager, window: NSApp.keyWindow)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SSHBookmarkEditView(bookmark: nil) { newBookmark in
                bookmarkStore.addBookmark(newBookmark, parentID: targetFolderID)
                targetFolderID = nil
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            SSHBookmarkEditView(bookmark: bookmark) { updated in
                bookmarkStore.update(updated)
            }
        }
        .sheet(isPresented: $showingAddCommandSheet) {
            CommandEditView(command: nil) { newCommand in
                commandStore.add(newCommand)
            }
        }
        .sheet(item: $editingCommand) { command in
            CommandEditView(command: command) { updated in
                commandStore.update(updated)
            }
        }
        .task {
            await updateChecker.checkForUpdates()
        }
        .alert("Update Available", isPresented: $updateChecker.updateAvailable) {
            if let downloadURL = updateChecker.downloadURL {
                Button("Download") {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
            if let releaseURL = updateChecker.releaseURL {
                Button("View Release") {
                    NSWorkspace.shared.open(releaseURL)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("MacTerminal \(updateChecker.latestVersion) is available.\n(Current: \(updateChecker.currentVersion))")
        }
        .alert("No Updates Available", isPresented: $updateChecker.upToDate) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("MacTerminal \(updateChecker.currentVersion) is the latest version.")
        }
    }

    private func connectToHost(_ bookmark: SSHBookmark) {
        let tab = tabManager.addTab(title: bookmark.name)

        if !bookmark.password.isEmpty {
            tab.terminal.pendingPassword = bookmark.password
        }

        var cmd = "ssh"
        if bookmark.port != 22 {
            cmd += " -p \(bookmark.port)"
        }
        cmd += " \(bookmark.username)@\(bookmark.host)\r"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tab.terminal.write(cmd)
        }
    }

    private func runCommand(_ command: CommandItem) {
        guard let tab = tabManager.selectedTab else { return }
        tab.terminal.write(command.command)
        DispatchQueue.main.async {
            if let drawView: TerminalDrawView = Self.findSubview(in: NSApp.keyWindow?.contentView) {
                drawView.window?.makeFirstResponder(drawView)
            }
        }
    }

    private static func findSubview<T: NSView>(in view: NSView?) -> T? {
        guard let view = view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews {
            if let found: T = findSubview(in: sub) { return found }
        }
        return nil
    }
}

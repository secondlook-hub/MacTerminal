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
}

struct ContentView: View {
    @EnvironmentObject var bookmarkStore: SSHBookmarkStore
    @StateObject private var tabManager = TabManager()
    @State private var selectedItemID: UUID?
    @State private var showingAddSheet = false
    @State private var editingBookmark: SSHBookmark?
    @State private var targetFolderID: UUID?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedItemID: $selectedItemID,
                showingAddSheet: $showingAddSheet,
                editingBookmark: $editingBookmark,
                targetFolderID: $targetFolderID,
                onConnect: connectToHost
            )
        } detail: {
            VStack(spacing: 0) {
                TabBarView(tabManager: tabManager)
                if let tab = tabManager.selectedTab {
                    TerminalView(tab: tab)
                        .id(tab.id)
                } else {
                    Color(nsColor: .terminalBG)
                }
            }
        }
        .focusedSceneValue(\.terminalScreen, tabManager.selectedTab?.screen)
        .focusedSceneValue(\.terminalTab, tabManager.selectedTab)
        .focusedSceneValue(\.isRecording, tabManager.selectedTab?.isRecording ?? false)
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
    }

    private func connectToHost(_ bookmark: SSHBookmark) {
        let tab = tabManager.addTab(title: bookmark.name)

        var cmd = "ssh"
        if let keyPath = bookmark.sshKeyPath, !keyPath.isEmpty {
            cmd += " -i \"\(keyPath)\""
        }
        if bookmark.port != 22 {
            cmd += " -p \(bookmark.port)"
        }
        cmd += " \(bookmark.username)@\(bookmark.host)\r"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tab.terminal.write(cmd)
        }
    }
}

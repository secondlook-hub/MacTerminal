import Foundation
import Combine

class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var windowTitle: String
    @Published var isRecording = false
    let terminal: PseudoTerminal
    let screen: TerminalScreen

    init(title: String) {
        self.title = title
        self.windowTitle = title
        self.terminal = PseudoTerminal()
        self.screen = TerminalScreen()
        self.screen.onTitleChange = { [weak self] newTitle in
            DispatchQueue.main.async { self?.windowTitle = newTitle }
        }
        self.screen.onCommandEntered = { [weak self] cmd in
            DispatchQueue.main.async { self?.title = cmd }
        }
    }

    func startRecording(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        screen.recordingHandle = try? FileHandle(forWritingTo: url)
        screen.recordingHandle?.seekToEndOfFile()
        isRecording = true
    }

    func stopRecording() {
        try? screen.recordingHandle?.close()
        screen.recordingHandle = nil
        isRecording = false
    }
}

struct TabDragData: Codable {
    let tabID: UUID
    let sourceManagerID: UUID
}

class TabManager: Identifiable, ObservableObject {
    let id = UUID()
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    private var tabObservers: [UUID: AnyCancellable] = [:]

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    init() {
        addLocalShellTab()
    }

    init(empty: Bool) {
        // No default shell tab
    }

    private func observeTab(_ tab: TerminalTab) {
        tabObservers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @discardableResult
    func addLocalShellTab() -> TerminalTab {
        let tab = TerminalTab(title: "Shell")
        tabs.append(tab)
        selectedTabID = tab.id
        observeTab(tab)
        tab.terminal.start()
        return tab
    }

    @discardableResult
    func addTab(title: String) -> TerminalTab {
        let tab = TerminalTab(title: title)
        tabs.append(tab)
        selectedTabID = tab.id
        observeTab(tab)
        tab.terminal.start()
        return tab
    }

    func removeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.terminal.stop()
        tabs.remove(at: idx)
        tabObservers.removeValue(forKey: id)

        if selectedTabID == id {
            if !tabs.isEmpty {
                let newIdx = min(idx, tabs.count - 1)
                selectedTabID = tabs[newIdx].id
            } else {
                selectedTabID = nil
            }
        }
    }

    /// Remove tab without stopping its terminal (for transferring between windows)
    func takeTab(_ id: UUID) -> TerminalTab? {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: idx)
        tabObservers.removeValue(forKey: id)

        if selectedTabID == id {
            if !tabs.isEmpty {
                let newIdx = min(idx, tabs.count - 1)
                selectedTabID = tabs[newIdx].id
            } else {
                selectedTabID = nil
            }
        }
        return tab
    }

    /// Insert an existing tab (from another window) without starting a new terminal
    func insertTab(_ tab: TerminalTab, at index: Int? = nil) {
        if let index = index, index >= 0, index <= tabs.count {
            tabs.insert(tab, at: index)
        } else {
            tabs.append(tab)
        }
        observeTab(tab)
        selectedTabID = tab.id
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
    }
}

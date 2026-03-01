import Foundation
import Combine

class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var windowTitle: String
    @Published var isRecording = false
    @Published var focusedPaneID: UUID
    var isActive = false
    var hasUpdate: Bool = false {
        didSet {
            if hasUpdate != oldValue {
                objectWillChange.send()
            }
        }
    }
    let rootNode: SplitNodeRef

    var terminal: PseudoTerminal { focusedPane.terminal }
    var screen: TerminalScreen { focusedPane.screen }

    var focusedPane: TerminalPane {
        rootNode.node.findPane(focusedPaneID)
            ?? rootNode.node.allPanes().first!
    }

    init(title: String) {
        self.title = title
        self.windowTitle = title
        let pane = TerminalPane()
        self.rootNode = SplitNodeRef(node: .leaf(pane))
        self.focusedPaneID = pane.id
        setupPaneCallbacks(pane)
    }

    func setupPaneCallbacks(_ pane: TerminalPane) {
        pane.screen.onTitleChange = { [weak self] newTitle in
            DispatchQueue.main.async { self?.windowTitle = newTitle }
        }
        pane.screen.onCommandEntered = { [weak self] cmd in
            DispatchQueue.main.async { self?.title = cmd }
        }
        pane.screen.onChange = { [weak self] in
            guard let self = self, !self.isActive else { return }
            DispatchQueue.main.async { [weak self] in
                self?.hasUpdate = true
            }
        }
    }

    func splitPane(axis: SplitAxis) {
        let currentPane = focusedPane
        let dir = currentPane.screen.currentDirectory
        let newPane = TerminalPane()
        setupPaneCallbacks(newPane)
        let oldLeaf = SplitNode.leaf(currentPane)
        let newLeaf = SplitNode.leaf(newPane)
        let splitNode = SplitNode.split(axis: axis, first: oldLeaf, second: newLeaf)
        rootNode.node = rootNode.node.replacingPane(focusedPaneID, with: splitNode)
        focusedPaneID = newPane.id
        newPane.terminal.start(workingDirectory: dir)
    }

    /// Returns true if the pane was closed (multi-pane). Returns false if this was the last pane.
    func closePane() -> Bool {
        guard case .split = rootNode.node else { return false }
        if let pane = rootNode.node.findPane(focusedPaneID) {
            pane.terminal.stop()
        }
        if let newRoot = rootNode.node.removingPane(focusedPaneID) {
            rootNode.node = newRoot
            if let firstPane = rootNode.node.allPanes().first {
                focusedPaneID = firstPane.id
            }
        }
        return true
    }

    func moveFocus(direction: FocusDirection) {
        let panes = rootNode.node.allPanes()
        guard panes.count > 1 else { return }
        guard let idx = panes.firstIndex(where: { $0.id == focusedPaneID }) else { return }
        switch direction {
        case .left, .up:
            focusedPaneID = panes[idx > 0 ? idx - 1 : panes.count - 1].id
        case .right, .down:
            focusedPaneID = panes[idx < panes.count - 1 ? idx + 1 : 0].id
        }
    }

    var isSplit: Bool {
        if case .split = rootNode.node { return true }
        return false
    }

    func closeSplit() {
        let panes = rootNode.node.allPanes()
        guard panes.count > 1 else { return }
        let keep = focusedPane
        for pane in panes where pane.id != keep.id {
            pane.terminal.stop()
        }
        rootNode.node = .leaf(keep)
        objectWillChange.send()
    }

    func stopAllTerminals() {
        for pane in rootNode.node.allPanes() {
            pane.terminal.stop()
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

    private func updateActiveTab() {
        for tab in tabs {
            tab.isActive = (tab.id == selectedTabID)
        }
    }

    @discardableResult
    func addLocalShellTab() -> TerminalTab {
        let dir = selectedTab?.screen.currentDirectory
        let tab = TerminalTab(title: "Shell")
        tabs.append(tab)
        selectedTabID = tab.id
        updateActiveTab()
        observeTab(tab)
        tab.terminal.start(workingDirectory: dir)
        return tab
    }

    @discardableResult
    func addTab(title: String) -> TerminalTab {
        let tab = TerminalTab(title: title)
        tabs.append(tab)
        selectedTabID = tab.id
        updateActiveTab()
        observeTab(tab)
        tab.terminal.start()
        return tab
    }

    func removeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.stopAllTerminals()
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
        updateActiveTab()
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
        updateActiveTab()
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
        updateActiveTab()
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
        updateActiveTab()
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.hasUpdate = false
        }
    }
}

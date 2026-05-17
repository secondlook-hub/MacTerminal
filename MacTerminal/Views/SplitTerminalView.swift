import SwiftUI
import AppKit
import Combine

/// Hosts the terminal area for the entire window. Keeps every tab's
/// TerminalContainerView (and its scrollback / scroll position / find bar
/// state) alive in a hidden subview so switching tabs is a single
/// `isHidden` toggle instead of tearing down and rebuilding the whole
/// scroll + draw view + find bar + status bar hierarchy.
struct TerminalDetailHost: NSViewRepresentable {
    @ObservedObject var tabManager: TabManager

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalDetailHostView {
        TerminalDetailHostView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: TerminalDetailHostView, context: Context) {
        nsView.update(tabManager: tabManager)
    }

    final class Coordinator {
        /// Cached per-tab built view (a TerminalContainerView for a leaf, or
        /// an NSSplitView for split layouts). Keyed by tab id.
        var tabEntries: [UUID: TabEntry] = [:]
        /// Cached per-pane container — survives split/unsplit operations.
        var paneCache: [UUID: TerminalContainerView] = [:]
    }

    final class TabEntry {
        let view: NSView
        let signature: String
        var subscriptions: Set<AnyCancellable> = []
        init(view: NSView, signature: String) {
            self.view = view
            self.signature = signature
        }
    }
}

final class TerminalDetailHostView: NSView {
    private let coordinator: TerminalDetailHost.Coordinator
    private weak var lastVisibleEntry: TerminalDetailHost.TabEntry?

    init(coordinator: TerminalDetailHost.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.terminalBG.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabManager: TabManager) {
        // Garbage-collect entries / containers for tabs and panes that no
        // longer exist. PseudoTerminal.stop() was already called by the
        // TabManager when the tab was removed.
        let liveTabIDs = Set(tabManager.tabs.map(\.id))
        for id in Array(coordinator.tabEntries.keys) where !liveTabIDs.contains(id) {
            coordinator.tabEntries[id]?.view.removeFromSuperview()
            coordinator.tabEntries.removeValue(forKey: id)
        }
        let livePaneIDs = Set(tabManager.tabs.flatMap { $0.rootNode.node.allPanes().map(\.id) })
        for id in Array(coordinator.paneCache.keys) where !livePaneIDs.contains(id) {
            coordinator.paneCache[id]?.removeFromSuperview()
            coordinator.paneCache.removeValue(forKey: id)
        }

        guard let tab = tabManager.selectedTab else {
            for entry in coordinator.tabEntries.values { entry.view.isHidden = true }
            lastVisibleEntry = nil
            return
        }

        let signature = Self.signature(for: tab.rootNode.node)
        var entry = coordinator.tabEntries[tab.id]
        if entry == nil || entry!.signature != signature {
            entry?.view.removeFromSuperview()
            let view = buildView(node: tab.rootNode.node, tab: tab)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            let newEntry = TerminalDetailHost.TabEntry(view: view, signature: signature)

            // React to tab state without going through SwiftUI body diffing.
            tab.$showTimestamp
                .dropFirst()
                .sink { [weak self] visible in
                    self?.applyShowTimestamp(visible, tab: tab)
                }
                .store(in: &newEntry.subscriptions)
            tab.$focusedPaneID
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.applyFocusBorder(tab: tab)
                    self.makeFocusedFirstResponder(tab: tab)
                }
                .store(in: &newEntry.subscriptions)
            // Detect split / close-split: rebuild only the affected tab.
            tab.rootNode.$node
                .dropFirst()
                .sink { [weak self, weak tabManager] _ in
                    guard let self = self, let tabManager = tabManager else { return }
                    DispatchQueue.main.async {
                        self.update(tabManager: tabManager)
                    }
                }
                .store(in: &newEntry.subscriptions)

            coordinator.tabEntries[tab.id] = newEntry
            entry = newEntry
        }

        // Reveal the selected tab, hide the rest.
        for (id, e) in coordinator.tabEntries {
            e.view.isHidden = (id != tab.id)
        }
        lastVisibleEntry = entry

        applyFocusBorder(tab: tab)
        makeFocusedFirstResponder(tab: tab)
    }

    // MARK: - Build

    private func buildView(node: SplitNode, tab: TerminalTab) -> NSView {
        switch node {
        case .leaf(let pane):
            return getOrMakeContainer(for: pane, tab: tab)
        case .split(let axis, let first, let second):
            let split = NSSplitView()
            split.isVertical = (axis == .horizontal)
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            let v1 = buildView(node: first, tab: tab)
            let v2 = buildView(node: second, tab: tab)
            v1.translatesAutoresizingMaskIntoConstraints = false
            v2.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(v1)
            split.addArrangedSubview(v2)
            return split
        }
    }

    private func getOrMakeContainer(for pane: TerminalPane, tab: TerminalTab) -> TerminalContainerView {
        if let cached = coordinator.paneCache[pane.id] {
            // The container may have been moved out of an old split view.
            // Detach so it can be re-arranged into a new parent.
            cached.removeFromSuperview()
            return cached
        }
        let container = TerminalContainerView(terminal: pane.terminal, screen: pane.screen)
        container.bindToPane(pane)
        container.onFocused = { [weak tab, paneID = pane.id] in
            tab?.focusedPaneID = paneID
        }
        if container.drawView.showTimestamp != tab.showTimestamp {
            container.drawView.showTimestamp = tab.showTimestamp
            container.drawView.updateTimestampLayout()
        }
        container.wantsLayer = true
        coordinator.paneCache[pane.id] = container
        return container
    }

    // MARK: - Per-tab state application

    private func applyShowTimestamp(_ visible: Bool, tab: TerminalTab) {
        for pane in tab.rootNode.node.allPanes() {
            guard let container = coordinator.paneCache[pane.id] else { continue }
            if container.drawView.showTimestamp != visible {
                container.drawView.showTimestamp = visible
                container.drawView.updateTimestampLayout()
                container.drawView.needsDisplay = true
                container.refreshDisplay()
            }
        }
    }

    private func applyFocusBorder(tab: TerminalTab) {
        let panes = tab.rootNode.node.allPanes()
        let hasMultiple = panes.count > 1
        for pane in panes {
            guard let container = coordinator.paneCache[pane.id] else { continue }
            container.wantsLayer = true
            let isFocused = hasMultiple && pane.id == tab.focusedPaneID
            container.layer?.borderColor = isFocused ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            container.layer?.borderWidth = isFocused ? 2 : 0
        }
    }

    private func makeFocusedFirstResponder(tab: TerminalTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let win = self.window else { return }
            if let pane = tab.rootNode.node.findPane(tab.focusedPaneID) ??
                          tab.rootNode.node.allPanes().first,
               let container = self.coordinator.paneCache[pane.id] {
                win.makeFirstResponder(container.drawView)
            }
        }
    }

    // MARK: - Signature

    /// String key that uniquely identifies the split layout for a tab. If it
    /// changes between updates, we know we need to rebuild the cached view.
    private static func signature(for node: SplitNode) -> String {
        switch node {
        case .leaf(let pane):
            return "L\(pane.id.uuidString)"
        case .split(let axis, let first, let second):
            return "S\(axis == .horizontal ? "h" : "v")(\(signature(for: first)),\(signature(for: second)))"
        }
    }
}

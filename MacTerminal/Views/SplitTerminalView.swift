import SwiftUI

struct SplitTerminalView: View {
    @ObservedObject var nodeRef: SplitNodeRef
    @ObservedObject var tab: TerminalTab

    var body: some View {
        let hasMultiple = nodeRef.node.allPanes().count > 1
        SplitNodeView(node: nodeRef.node, tab: tab, hasMultiplePanes: hasMultiple)
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    @ObservedObject var tab: TerminalTab
    let hasMultiplePanes: Bool

    var body: some View {
        switch node {
        case .leaf(let pane):
            TerminalPaneView(pane: pane, tab: tab, showBorder: hasMultiplePanes)
        case .split(let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    SplitNodeView(node: first, tab: tab, hasMultiplePanes: hasMultiplePanes)
                    SplitNodeView(node: second, tab: tab, hasMultiplePanes: hasMultiplePanes)
                }
            } else {
                VSplitView {
                    SplitNodeView(node: first, tab: tab, hasMultiplePanes: hasMultiplePanes)
                    SplitNodeView(node: second, tab: tab, hasMultiplePanes: hasMultiplePanes)
                }
            }
        }
    }
}

struct TerminalPaneView: View {
    let pane: TerminalPane
    @ObservedObject var tab: TerminalTab
    let showBorder: Bool

    var body: some View {
        TerminalPaneRepresentable(pane: pane, tab: tab)
            .overlay(
                Group {
                    if showBorder && tab.focusedPaneID == pane.id {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
            )
            .id(pane.id)
    }
}

struct TerminalPaneRepresentable: NSViewRepresentable {
    let pane: TerminalPane
    @ObservedObject var tab: TerminalTab

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminal: pane.terminal, screen: pane.screen)
        container.onFocused = { [weak tab, paneID = pane.id] in
            tab?.focusedPaneID = paneID
        }
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let isFocused = tab.focusedPaneID == pane.id
        if isFocused && !context.coordinator.lastFocusedState {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView.drawView)
            }
        }
        context.coordinator.lastFocusedState = isFocused
    }

    class Coordinator {
        var lastFocusedState = false
    }
}

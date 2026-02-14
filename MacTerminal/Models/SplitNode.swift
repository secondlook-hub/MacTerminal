import Foundation

class TerminalPane: Identifiable, ObservableObject {
    let id = UUID()
    let terminal: PseudoTerminal
    let screen: TerminalScreen

    init() {
        self.terminal = PseudoTerminal()
        self.screen = TerminalScreen()
    }
}

enum SplitAxis: Equatable {
    case horizontal   // left | right
    case vertical     // top / bottom
}

indirect enum SplitNode: Equatable {
    case leaf(TerminalPane)
    case split(axis: SplitAxis, first: SplitNode, second: SplitNode)

    static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
        switch (lhs, rhs) {
        case (.leaf(let a), .leaf(let b)):
            return a.id == b.id
        case (.split(let aAxis, let aFirst, let aSecond),
              .split(let bAxis, let bFirst, let bSecond)):
            return aAxis == bAxis && aFirst == bFirst && aSecond == bSecond
        default:
            return false
        }
    }

    func findPane(_ id: UUID) -> TerminalPane? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, let first, let second):
            return first.findPane(id) ?? second.findPane(id)
        }
    }

    func allPanes() -> [TerminalPane] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, let first, let second):
            return first.allPanes() + second.allPanes()
        }
    }

    func replacingPane(_ id: UUID, with newNode: SplitNode) -> SplitNode {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? newNode : self
        case .split(let axis, let first, let second):
            return .split(
                axis: axis,
                first: first.replacingPane(id, with: newNode),
                second: second.replacingPane(id, with: newNode)
            )
        }
    }

    func removingPane(_ id: UUID) -> SplitNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? nil : self
        case .split(let axis, let first, let second):
            let newFirst = first.removingPane(id)
            let newSecond = second.removingPane(id)
            if newFirst == nil { return newSecond }
            if newSecond == nil { return newFirst }
            return .split(axis: axis, first: newFirst!, second: newSecond!)
        }
    }
}

class SplitNodeRef: ObservableObject {
    @Published var node: SplitNode

    init(node: SplitNode) {
        self.node = node
    }
}

enum FocusDirection {
    case left, right, up, down
}

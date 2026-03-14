import Foundation
import AppKit

class InputHistoryManager {
    static let shared = InputHistoryManager()
    private let key = "inputHistory"
    private let clearOnExitKey = "clearHistoryOnExit"
    private let maxItems = 500

    private(set) var history: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var clearOnExit: Bool {
        get { UserDefaults.standard.bool(forKey: clearOnExitKey) }
        set { UserDefaults.standard.set(newValue, forKey: clearOnExitKey) }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func appWillTerminate() {
        if clearOnExit {
            clear()
        }
    }

    func add(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = history
        // Remove duplicate if exists
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxItems {
            list = Array(list.prefix(maxItems))
        }
        history = list
    }

    func clear() {
        history = []
    }
}

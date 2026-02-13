import AppKit
import SwiftUI

class WindowManager {
    static let shared = WindowManager()

    private var registrations: [UUID: Registration] = [:]

    struct Registration {
        let tabManager: TabManager
        weak var window: NSWindow?
        let isDetached: Bool
    }

    private init() {}

    func register(_ tabManager: TabManager, window: NSWindow?, isDetached: Bool = false) {
        registrations[tabManager.id] = Registration(
            tabManager: tabManager, window: window, isDetached: isDetached
        )
    }

    func unregister(_ managerID: UUID) {
        registrations.removeValue(forKey: managerID)
    }

    func tabManager(for id: UUID) -> TabManager? {
        registrations[id]?.tabManager
    }

    // MARK: - Detach Tab

    func detachTab(tabID: UUID, from sourceManagerID: UUID, at screenPoint: NSPoint? = nil) {
        guard let sourceReg = registrations[sourceManagerID],
              let tab = sourceReg.tabManager.takeTab(tabID) else { return }

        let newManager = TabManager(empty: true)
        newManager.insertTab(tab)

        let window = createDetachedWindow(for: newManager, at: screenPoint)
        register(newManager, window: window, isDetached: true)

        // Close source detached window if empty
        if sourceReg.isDetached && sourceReg.tabManager.tabs.isEmpty {
            closeDetachedWindow(for: sourceManagerID)
        }
    }

    // MARK: - Transfer Tab Between Windows

    func transferTab(tabID: UUID, from sourceManagerID: UUID, to destManagerID: UUID, at index: Int? = nil) {
        guard sourceManagerID != destManagerID,
              let sourceReg = registrations[sourceManagerID],
              let destReg = registrations[destManagerID],
              let tab = sourceReg.tabManager.takeTab(tabID) else { return }

        destReg.tabManager.insertTab(tab, at: index)

        // Close source detached window if empty
        if sourceReg.isDetached && sourceReg.tabManager.tabs.isEmpty {
            closeDetachedWindow(for: sourceManagerID)
        }
    }

    // MARK: - Window Management

    private func createDetachedWindow(for tabManager: TabManager, at screenPoint: NSPoint? = nil) -> NSWindow {
        let content = DetachedWindowContent(tabManager: tabManager)
        let hostingView = NSHostingView(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = tabManager.selectedTab?.title ?? "Terminal"
        window.isReleasedWhenClosed = false

        if let pt = screenPoint {
            let origin = NSPoint(x: pt.x - 400, y: pt.y - 250)
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        let delegate = DetachedWindowDelegate(managerID: tabManager.id)
        window.delegate = delegate
        // Keep delegate alive
        objc_setAssociatedObject(window, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        window.makeKeyAndOrderFront(nil)
        return window
    }

    func closeDetachedWindow(for managerID: UUID) {
        guard let reg = registrations[managerID], reg.isDetached else { return }
        // Stop all remaining terminals
        for tab in reg.tabManager.tabs {
            tab.terminal.stop()
        }
        reg.window?.close()
        unregister(managerID)
    }
}

// MARK: - Detached Window Delegate

class DetachedWindowDelegate: NSObject, NSWindowDelegate {
    let managerID: UUID

    init(managerID: UUID) {
        self.managerID = managerID
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        let wm = WindowManager.shared
        if let tabManager = wm.tabManager(for: managerID) {
            for tab in tabManager.tabs {
                tab.terminal.stop()
            }
        }
        wm.unregister(managerID)
    }
}

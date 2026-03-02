import SwiftUI

struct DetachedWindowContent: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(tabManager: tabManager)
            if let tab = tabManager.selectedTab {
                SplitTerminalView(nodeRef: tab.rootNode, tab: tab)
                    .id(tab.id)
            } else {
                Color(nsColor: .terminalBG)
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
        .focusedSceneValue(\.terminalScreen, tabManager.selectedTab?.screen)
        .focusedSceneValue(\.terminalTab, tabManager.selectedTab)
        .focusedSceneValue(\.isRecording, tabManager.selectedTab?.isRecording ?? false)
        .focusedSceneValue(\.tabManager, tabManager)
        .onReceive(tabManager.$tabs) { tabs in
            if tabs.isEmpty {
                // Defer to next RunLoop iteration to avoid race condition:
                // @Published fires on willSet (before value is stored), so during
                // transferTab's takeTab(), the stored tabs still contains the tab.
                // Calling closeDetachedWindow synchronously would stop the terminal.
                DispatchQueue.main.async {
                    WindowManager.shared.closeDetachedWindow(for: tabManager.id)
                }
            }
        }
    }
}

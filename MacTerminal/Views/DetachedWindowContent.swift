import SwiftUI

struct DetachedWindowContent: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(tabManager: tabManager)
            if let tab = tabManager.selectedTab {
                TerminalView(tab: tab)
                    .id(tab.id)
            } else {
                Color(nsColor: .terminalBG)
            }
        }
        .focusedSceneValue(\.terminalScreen, tabManager.selectedTab?.screen)
        .onReceive(tabManager.$tabs) { tabs in
            if tabs.isEmpty {
                WindowManager.shared.closeDetachedWindow(for: tabManager.id)
            }
        }
    }
}

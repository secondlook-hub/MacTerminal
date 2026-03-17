import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable {
    case connections = "Connections"
    case commands = "Commands"
}

struct SidebarView: View {
    @EnvironmentObject var bookmarkStore: SSHBookmarkStore
    @EnvironmentObject var commandStore: CommandStore
    @Binding var selectedItemID: UUID?
    @Binding var showingAddSheet: Bool
    @Binding var editingBookmark: SSHBookmark?
    @Binding var targetFolderID: UUID?
    @Binding var showingAddCommandSheet: Bool
    @Binding var editingCommand: CommandItem?
    var onConnect: (SSHBookmark) -> Void
    var onRunCommand: (CommandItem) -> Void

    @State private var sidebarTab: SidebarTab = .connections
    @State private var renamingFolderID: UUID?
    @State private var renameFolderName: String = ""
    @State private var draggedItemID: UUID?
    @State private var selectedCommandID: UUID?
    @State private var expandedFolderIDs: Set<UUID> = Self.loadExpandedFolders()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            switch sidebarTab {
            case .connections:
                connectionsTab
            case .commands:
                commandsTab
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if sidebarTab == .connections {
                    connectionsToolbar
                } else {
                    commandsToolbar
                }
            }
        }
        .sheet(isPresented: showingRenameAlert) {
            RenameFolderSheet(name: renameFolderName) { newName in
                if let id = renamingFolderID, !newName.isEmpty {
                    bookmarkStore.renameFolder(id: id, newName: newName)
                }
                renamingFolderID = nil
            } onCancel: {
                renamingFolderID = nil
            }
        }
    }

    // MARK: - Connections Tab

    private var connectionsTab: some View {
        List {
            ForEach(bookmarkStore.rootItems) { item in
                SidebarTreeItemView(
                    item: item,
                    selectedItemID: $selectedItemID,
                    draggedItemID: $draggedItemID,
                    expandedFolderIDs: $expandedFolderIDs,
                    bookmarkStore: bookmarkStore,
                    folderContextMenu: { folderContextMenu($0) },
                    bookmarkContextMenu: { bookmarkContextMenu($0) },
                    saveExpanded: { Self.saveExpandedFolders($0) },
                    onConnect: onConnect
                )
            }
        }
        .background(ListEmptyAreaTapHandler { selectedItemID = nil })
        .safeAreaInset(edge: .bottom) {
            if let bm = selectedBookmark {
                Button(action: { onConnect(bm) }) {
                    Label("Connect", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }

    private static func loadExpandedFolders() -> Set<UUID> {
        guard let strings = UserDefaults.standard.stringArray(forKey: "expandedFolderIDs") else { return [] }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private static func saveExpandedFolders(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: "expandedFolderIDs")
    }

    // MARK: - Commands Tab

    private var commandsTab: some View {
        List {
            ForEach(commandStore.commands) { cmd in
                CommandRow(command: cmd)
                    .tag(cmd.id)
                    .listRowBackground(commandRowBackground(for: cmd.id))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedCommandID = cmd.id }
                    .gesture(TapGesture(count: 2).onEnded { onRunCommand(cmd) })
                    .contextMenu {
                        Button("Run") { onRunCommand(cmd) }
                        Divider()
                        Button("Move Up") {
                            commandStore.moveUp(id: cmd.id)
                        }
                        .disabled(!commandStore.canMoveUp(id: cmd.id))
                        Button("Move Down") {
                            commandStore.moveDown(id: cmd.id)
                        }
                        .disabled(!commandStore.canMoveDown(id: cmd.id))
                        Divider()
                        Button("Edit...") { editingCommand = cmd }
                        Button("Delete", role: .destructive) {
                            commandStore.delete(id: cmd.id)
                            if selectedCommandID == cmd.id {
                                selectedCommandID = nil
                            }
                        }
                    }
            }
            .onMove { commandStore.move(fromOffsets: $0, toOffset: $1) }
        }
        .background(ListEmptyAreaTapHandler { selectedCommandID = nil })
        .safeAreaInset(edge: .bottom) {
            if let cmd = selectedCommand {
                Button(action: { onRunCommand(cmd) }) {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }

    // MARK: - Toolbars

    private var connectionsToolbar: some View {
        Menu {
            Button("New Connection...") {
                if let id = selectedItemID,
                   let item = bookmarkStore.findItem(byID: id),
                   item.isFolder {
                    targetFolderID = id
                } else {
                    targetFolderID = nil
                }
                showingAddSheet = true
            }
            Button("New Folder") {
                bookmarkStore.addFolder(name: "New Folder", parentID: selectedFolderID)
            }
        } label: {
            Image(systemName: "plus")
        }
        .help("Add Connection or Folder")
    }

    private var commandsToolbar: some View {
        Button(action: { showingAddCommandSheet = true }) {
            Image(systemName: "plus")
        }
        .help("Add Command")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func rowBackground(for id: UUID) -> some View {
        if selectedItemID == id {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func commandRowBackground(for id: UUID) -> some View {
        if selectedCommandID == id {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
        } else {
            Color.clear
        }
    }

    private var selectedBookmark: SSHBookmark? {
        bookmarkStore.findBookmark(byID: selectedItemID)
    }

    private var selectedFolderID: UUID? {
        guard let id = selectedItemID,
              let item = bookmarkStore.findItem(byID: id),
              item.isFolder else { return nil }
        return id
    }

    private var selectedCommand: CommandItem? {
        guard let id = selectedCommandID else { return nil }
        return commandStore.commands.first { $0.id == id }
    }

    private var showingRenameAlert: Binding<Bool> {
        Binding(
            get: { renamingFolderID != nil },
            set: { if !$0 { renamingFolderID = nil } }
        )
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func folderContextMenu(_ item: SidebarItem) -> some View {
        Button("New Connection Here...") {
            targetFolderID = item.id
            showingAddSheet = true
        }
        Button("New Subfolder") {
            bookmarkStore.addFolder(name: "New Folder", parentID: item.id)
        }
        Divider()
        Button("Move Up") {
            bookmarkStore.moveUp(id: item.id)
        }
        .disabled(!bookmarkStore.canMoveUp(id: item.id))
        Button("Move Down") {
            bookmarkStore.moveDown(id: item.id)
        }
        .disabled(!bookmarkStore.canMoveDown(id: item.id))
        Divider()
        Button("Rename...") {
            renameFolderName = item.name
            renamingFolderID = item.id
        }
        Button("Delete", role: .destructive) {
            bookmarkStore.deleteItem(id: item.id)
            if selectedItemID == item.id { selectedItemID = nil }
        }
    }

    @ViewBuilder
    private func bookmarkContextMenu(_ bookmark: SSHBookmark) -> some View {
        Button("Connect") { onConnect(bookmark) }
        Divider()
        Button("Move Up") {
            bookmarkStore.moveUp(id: bookmark.id)
        }
        .disabled(!bookmarkStore.canMoveUp(id: bookmark.id))
        Button("Move Down") {
            bookmarkStore.moveDown(id: bookmark.id)
        }
        .disabled(!bookmarkStore.canMoveDown(id: bookmark.id))
        Divider()
        Button("Edit...") { editingBookmark = bookmark }
        Button("Delete", role: .destructive) {
            bookmarkStore.delete(bookmark)
            if selectedItemID == bookmark.id { selectedItemID = nil }
        }
    }
}

// MARK: - Row Views

struct SidebarItemRow: View {
    let item: SidebarItem

    var body: some View {
        if item.isFolder {
            FolderRow(name: item.name)
        } else if let bookmark = item.bookmark {
            BookmarkRow(bookmark: bookmark)
        }
    }
}

struct FolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .font(.title3)
            Text(name)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct BookmarkRow: View {
    let bookmark: SSHBookmark

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundColor(.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(bookmark.username)@\(bookmark.host)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if bookmark.port != 22 {
                    Text("Port: \(bookmark.port)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct CommandRow: View {
    let command: CommandItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundColor(.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(command.command)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sidebar Tree Item (Recursive)

struct SidebarTreeItemView<FolderMenu: View, BookmarkMenu: View>: View {
    let item: SidebarItem
    @Binding var selectedItemID: UUID?
    @Binding var draggedItemID: UUID?
    @Binding var expandedFolderIDs: Set<UUID>
    let bookmarkStore: SSHBookmarkStore
    let folderContextMenu: (SidebarItem) -> FolderMenu
    let bookmarkContextMenu: (SSHBookmark) -> BookmarkMenu
    let saveExpanded: (Set<UUID>) -> Void
    var onConnect: ((SSHBookmark) -> Void)?

    var body: some View {
        if item.isFolder {
            DisclosureGroup(isExpanded: folderBinding) {
                if let children = item.children {
                    ForEach(children) { child in
                        SidebarTreeItemView(
                            item: child,
                            selectedItemID: $selectedItemID,
                            draggedItemID: $draggedItemID,
                            expandedFolderIDs: $expandedFolderIDs,
                            bookmarkStore: bookmarkStore,
                            folderContextMenu: folderContextMenu,
                            bookmarkContextMenu: bookmarkContextMenu,
                            saveExpanded: saveExpanded,
                            onConnect: onConnect
                        )
                    }
                }
            } label: {
                rowContent
            }
        } else {
            rowContent
        }
    }

    private var folderBinding: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(item.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderIDs.insert(item.id)
                } else {
                    expandedFolderIDs.remove(item.id)
                }
                saveExpanded(expandedFolderIDs)
            }
        )
    }

    @ViewBuilder
    private func itemRowBackground(for id: UUID) -> some View {
        if selectedItemID == id {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
        } else {
            Color.clear
        }
    }

    private var rowContent: some View {
        SidebarItemRow(item: item)
            .tag(item.id)
            .listRowBackground(itemRowBackground(for: item.id))
            .contentShape(Rectangle())
            .onTapGesture { selectedItemID = item.id }
            .gesture(TapGesture(count: 2).onEnded {
                if let bm = item.bookmark, let onConnect = onConnect {
                    onConnect(bm)
                }
            })
            .onDrag {
                draggedItemID = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [.plainText], delegate: SidebarDropDelegate(
                targetItem: item,
                bookmarkStore: bookmarkStore,
                draggedItemID: $draggedItemID
            ))
            .contextMenu {
                if item.isFolder {
                    folderContextMenu(item)
                } else if let bm = item.bookmark {
                    bookmarkContextMenu(bm)
                }
            }
    }
}

// MARK: - Drag & Drop

struct SidebarDropDelegate: DropDelegate {
    let targetItem: SidebarItem
    let bookmarkStore: SSHBookmarkStore
    @Binding var draggedItemID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedID = draggedItemID else { return false }
        if draggedID == targetItem.id { return false }
        if bookmarkStore.isDescendant(targetItem.id, of: draggedID) { return false }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedID = draggedItemID else {
            return DropProposal(operation: .forbidden)
        }
        if draggedID == targetItem.id {
            return DropProposal(operation: .forbidden)
        }
        if bookmarkStore.isDescendant(targetItem.id, of: draggedID) {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = draggedItemID else { return false }
        if draggedID == targetItem.id { return false }
        if bookmarkStore.isDescendant(targetItem.id, of: draggedID) { return false }

        if targetItem.isFolder {
            let childCount = targetItem.children?.count ?? 0
            bookmarkStore.moveItem(id: draggedID, toParentID: targetItem.id, atIndex: childCount)
        } else {
            if let location = bookmarkStore.findLocation(of: targetItem.id) {
                bookmarkStore.moveItem(id: draggedID, toParentID: location.parentID, atIndex: location.index + 1)
            }
        }

        draggedItemID = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

// MARK: - Empty Area Click Handler

struct ListEmptyAreaTapHandler: NSViewRepresentable {
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let scrollView = Self.findEnclosingScrollView(of: view) else { return }
            let gesture = NSClickGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleClick(_:))
            )
            gesture.delaysPrimaryMouseButtonEvents = false
            scrollView.addGestureRecognizer(gesture)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTap = onTap
    }

    private static func findEnclosingScrollView(of view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = v as? NSScrollView { return sv }
            current = v.superview
        }
        return nil
    }

    class Coordinator: NSObject {
        var onTap: () -> Void

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scrollView = gesture.view as? NSScrollView else { return }
            if let tableView = Self.findTableView(in: scrollView) {
                let point = gesture.location(in: tableView)
                if tableView.row(at: point) < 0 {
                    onTap()
                }
            }
        }

        private static func findTableView(in view: NSView) -> NSTableView? {
            if let tv = view as? NSTableView { return tv }
            for sub in view.subviews {
                if let found = findTableView(in: sub) { return found }
            }
            return nil
        }
    }
}

// MARK: - Rename Folder Sheet

struct RenameFolderSheet: View {
    @State private var name: String
    @FocusState private var isFocused: Bool
    var onRename: (String) -> Void
    var onCancel: () -> Void

    init(name: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        self.onRename = onRename
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
            TextField("Folder name", text: $name)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onRename(name) }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { onRename(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var bookmarkStore: SSHBookmarkStore
    @Binding var selectedItemID: UUID?
    @Binding var showingAddSheet: Bool
    @Binding var editingBookmark: SSHBookmark?
    @Binding var targetFolderID: UUID?
    var onConnect: (SSHBookmark) -> Void

    @State private var renamingFolderID: UUID?
    @State private var renameFolderName: String = ""
    @State private var draggedItemID: UUID?

    var body: some View {
        List {
            Section("SSH Connections") {
                OutlineGroup(bookmarkStore.rootItems, children: \.children) { item in
                    SidebarItemRow(item: item)
                        .tag(item.id)
                        .listRowBackground(rowBackground(for: item.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedItemID = item.id
                        }
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
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
        }
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
        .alert("Rename Folder", isPresented: showingRenameAlert) {
            TextField("Folder name", text: $renameFolderName)
            Button("Cancel", role: .cancel) {
                renamingFolderID = nil
            }
            Button("Rename") {
                if let id = renamingFolderID, !renameFolderName.isEmpty {
                    bookmarkStore.renameFolder(id: id, newName: renameFolderName)
                }
                renamingFolderID = nil
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func rowBackground(for id: UUID) -> some View {
        if selectedItemID == id {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.2))
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
        Button("Rename...") {
            renameFolderName = item.name
            renamingFolderID = item.id
        }
        Button("Delete", role: .destructive) {
            bookmarkStore.deleteItem(id: item.id)
            if selectedItemID == item.id {
                selectedItemID = nil
            }
        }
    }

    @ViewBuilder
    private func bookmarkContextMenu(_ bookmark: SSHBookmark) -> some View {
        Button("Connect") {
            onConnect(bookmark)
        }
        Divider()
        Button("Edit...") {
            editingBookmark = bookmark
        }
        Button("Delete", role: .destructive) {
            bookmarkStore.delete(bookmark)
            if selectedItemID == bookmark.id {
                selectedItemID = nil
            }
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

    func dropExited(info: DropInfo) {
        // Keep draggedItemID alive for other drop targets
    }
}

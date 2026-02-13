import Foundation

class SSHBookmarkStore: ObservableObject {
    @Published var rootItems: [SidebarItem] = []

    private let fileURL: URL

    /// Backward-compatible computed property: collects all bookmarks from the tree.
    var bookmarks: [SSHBookmark] {
        collectBookmarks(from: rootItems)
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacTerminal")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("bookmarks.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            // Try v2 tree format first
            if let tree = try? JSONDecoder().decode(BookmarkTreeFile.self, from: data), tree.version >= 2 {
                rootItems = tree.rootItems
            } else {
                // Migrate from v1 flat array
                let legacyBookmarks = try JSONDecoder().decode([SSHBookmark].self, from: data)
                rootItems = legacyBookmarks.map { SidebarItem.bookmarkItem($0) }
                save() // persist as v2
            }
        } catch {
            print("Failed to load bookmarks: \(error)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let tree = BookmarkTreeFile(version: 2, rootItems: rootItems)
            let data = try encoder.encode(tree)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save bookmarks: \(error)")
        }
    }

    // MARK: - Bookmark CRUD (backward-compatible)

    func add(_ bookmark: SSHBookmark) {
        rootItems.append(SidebarItem.bookmarkItem(bookmark))
        save()
    }

    func update(_ bookmark: SSHBookmark) {
        if updateBookmarkInTree(bookmark, in: &rootItems) {
            rootItems = rootItems // trigger @Published
            save()
        }
    }

    func delete(_ bookmark: SSHBookmark) {
        if removeItem(id: bookmark.id, from: &rootItems) {
            rootItems = rootItems
            save()
        }
    }

    // MARK: - Tree Operations

    func addFolder(name: String, parentID: UUID? = nil) {
        let folder = SidebarItem.folder(name: name)
        if let parentID = parentID {
            if insertItem(folder, parentID: parentID, in: &rootItems) {
                rootItems = rootItems
            }
        } else {
            rootItems.append(folder)
        }
        save()
    }

    func renameFolder(id: UUID, newName: String) {
        if renameItem(id: id, newName: newName, in: &rootItems) {
            rootItems = rootItems
            save()
        }
    }

    func addBookmark(_ bookmark: SSHBookmark, parentID: UUID?) {
        let item = SidebarItem.bookmarkItem(bookmark)
        if let parentID = parentID {
            if insertItem(item, parentID: parentID, in: &rootItems) {
                rootItems = rootItems
            }
        } else {
            rootItems.append(item)
        }
        save()
    }

    func deleteItem(id: UUID) {
        if removeItem(id: id, from: &rootItems) {
            rootItems = rootItems
            save()
        }
    }

    func moveItem(id: UUID, toParentID: UUID?, atIndex: Int) {
        guard let item = findAndRemoveItem(id: id, from: &rootItems) else { return }
        if let parentID = toParentID {
            insertItemAtIndex(item, parentID: parentID, index: atIndex, in: &rootItems)
        } else {
            let idx = min(atIndex, rootItems.count)
            rootItems.insert(item, at: idx)
        }
        rootItems = rootItems
        save()
    }

    func findBookmark(byID id: UUID?) -> SSHBookmark? {
        guard let id = id else { return nil }
        return findBookmarkInTree(id: id, in: rootItems)
    }

    func findItem(byID id: UUID?) -> SidebarItem? {
        guard let id = id else { return nil }
        return findItemInTree(id: id, in: rootItems)
    }

    // MARK: - Tree Query Helpers

    /// Returns (parentID, index) of an item. parentID is nil for root-level items.
    func findLocation(of itemID: UUID) -> (parentID: UUID?, index: Int)? {
        return findLocationInTree(of: itemID, in: rootItems, parentID: nil)
    }

    /// Checks if `itemID` is a descendant of `ancestorID` (cycle prevention).
    func isDescendant(_ itemID: UUID, of ancestorID: UUID) -> Bool {
        guard let ancestor = findItemInTree(id: ancestorID, in: rootItems),
              let children = ancestor.children else { return false }
        return findItemInTree(id: itemID, in: children) != nil
    }

    private func findLocationInTree(of itemID: UUID, in items: [SidebarItem], parentID: UUID?) -> (parentID: UUID?, index: Int)? {
        for (index, item) in items.enumerated() {
            if item.id == itemID {
                return (parentID, index)
            }
            if let children = item.children {
                if let found = findLocationInTree(of: itemID, in: children, parentID: item.id) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Recursive Helpers

    private func collectBookmarks(from items: [SidebarItem]) -> [SSHBookmark] {
        var result: [SSHBookmark] = []
        for item in items {
            if let bm = item.bookmark {
                result.append(bm)
            }
            if let children = item.children {
                result.append(contentsOf: collectBookmarks(from: children))
            }
        }
        return result
    }

    @discardableResult
    private func updateBookmarkInTree(_ bookmark: SSHBookmark, in items: inout [SidebarItem]) -> Bool {
        for i in items.indices {
            if items[i].id == bookmark.id {
                items[i].bookmark = bookmark
                items[i].name = bookmark.name
                return true
            }
            if items[i].children != nil {
                if updateBookmarkInTree(bookmark, in: &items[i].children!) {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private func removeItem(id: UUID, from items: inout [SidebarItem]) -> Bool {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: idx)
            return true
        }
        for i in items.indices {
            if items[i].children != nil {
                if removeItem(id: id, from: &items[i].children!) {
                    return true
                }
            }
        }
        return false
    }

    private func findAndRemoveItem(id: UUID, from items: inout [SidebarItem]) -> SidebarItem? {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            return items.remove(at: idx)
        }
        for i in items.indices {
            if items[i].children != nil {
                if let found = findAndRemoveItem(id: id, from: &items[i].children!) {
                    return found
                }
            }
        }
        return nil
    }

    @discardableResult
    private func insertItem(_ item: SidebarItem, parentID: UUID, in items: inout [SidebarItem]) -> Bool {
        for i in items.indices {
            if items[i].id == parentID && items[i].isFolder {
                items[i].children?.append(item)
                return true
            }
            if items[i].children != nil {
                if insertItem(item, parentID: parentID, in: &items[i].children!) {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private func insertItemAtIndex(_ item: SidebarItem, parentID: UUID, index: Int, in items: inout [SidebarItem]) -> Bool {
        for i in items.indices {
            if items[i].id == parentID && items[i].isFolder {
                let idx = min(index, items[i].children?.count ?? 0)
                items[i].children?.insert(item, at: idx)
                return true
            }
            if items[i].children != nil {
                if insertItemAtIndex(item, parentID: parentID, index: index, in: &items[i].children!) {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private func renameItem(id: UUID, newName: String, in items: inout [SidebarItem]) -> Bool {
        for i in items.indices {
            if items[i].id == id {
                items[i].name = newName
                return true
            }
            if items[i].children != nil {
                if renameItem(id: id, newName: newName, in: &items[i].children!) {
                    return true
                }
            }
        }
        return false
    }

    private func findBookmarkInTree(id: UUID, in items: [SidebarItem]) -> SSHBookmark? {
        for item in items {
            if item.id == id, let bm = item.bookmark {
                return bm
            }
            if let children = item.children, let found = findBookmarkInTree(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    private func findItemInTree(id: UUID, in items: [SidebarItem]) -> SidebarItem? {
        for item in items {
            if item.id == id {
                return item
            }
            if let children = item.children, let found = findItemInTree(id: id, in: children) {
                return found
            }
        }
        return nil
    }
}

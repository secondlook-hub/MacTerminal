import Foundation

struct SidebarItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var isFolder: Bool
    var bookmark: SSHBookmark?
    var children: [SidebarItem]?

    /// Create a folder node
    static func folder(name: String, children: [SidebarItem] = []) -> SidebarItem {
        SidebarItem(id: UUID(), name: name, isFolder: true, bookmark: nil, children: children)
    }

    /// Create a bookmark leaf node
    static func bookmarkItem(_ bookmark: SSHBookmark) -> SidebarItem {
        SidebarItem(id: bookmark.id, name: bookmark.name, isFolder: false, bookmark: bookmark, children: nil)
    }
}

struct BookmarkTreeFile: Codable {
    var version: Int
    var rootItems: [SidebarItem]
}

import SwiftUI

struct FileItem: Identifiable, Comparable {
    let id = UUID()
    let name: String
    let path: String
    var children: [FileItem]?

    static func < (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

class DirectoryTreeModel: ObservableObject {
    @Published var rootItems: [FileItem] = []
    @Published var expandedPaths: Set<String> = []
    @Published var currentDirectory: String = ""
    @Published var selectedPath: String?

    let homePath = NSHomeDirectory()

    func navigateTo(path: String) {
        guard !path.isEmpty else { return }
        currentDirectory = path
        if rootItems.isEmpty {
            rootItems = loadChildren(at: "/")
            expandToPath(path)
        }
    }

    @Published var scrollToPath: String?

    func directoryChanged(_ path: String) {
        guard !path.isEmpty, path != currentDirectory else { return }
        currentDirectory = path
        selectedPath = path
        rootItems = loadChildren(at: "/")
        expandToPath(path)
        // Delay scroll to allow SwiftUI to lay out the expanded tree
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollToPath = path
        }
    }

    func refresh() {
        let dir = currentDirectory
        rootItems = loadChildren(at: "/")
        expandToPath(dir)
    }

    func loadChildren(at path: String) -> [FileItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var items: [FileItem] = []
        for name in entries {
            if name.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let item = FileItem(
                name: name,
                path: fullPath,
                children: []
            )
            items.append(item)
        }
        return items.sorted()
    }

    func isExpanded(_ item: FileItem) -> Bool {
        expandedPaths.contains(item.path)
    }

    private func expandToPath(_ targetPath: String) {
        var current = ""
        for comp in targetPath.split(separator: "/") {
            current += "/" + comp
            expandedPaths.insert(current)
        }
        objectWillChange.send()
    }
}

struct DirectoryTreeView: View {
    @ObservedObject var model: DirectoryTreeModel
    var onChangeDirectory: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text(abbreviatePath(model.currentDirectory))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .separatorColor).opacity(0.2))

            Divider()

            if model.rootItems.isEmpty {
                VStack {
                    Spacer()
                    Text("No directories")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(model.rootItems) { item in
                            DirectoryTreeRow(
                                item: item,
                                model: model,
                                onChangeDirectory: onChangeDirectory
                            )
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: model.scrollToPath) { target in
                        if let target = target {
                            withAnimation {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            model.scrollToPath = nil
                        }
                    }
                }
            }
        }
        .frame(minWidth: 180)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct DirectoryTreeRow: View {
    let item: FileItem
    @ObservedObject var model: DirectoryTreeModel
    var onChangeDirectory: ((String) -> Void)?

    private var isSelected: Bool {
        item.path == model.selectedPath
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { model.isExpanded(item) },
                set: { expanded in
                    if expanded {
                        model.expandedPaths.insert(item.path)
                    } else {
                        model.expandedPaths.remove(item.path)
                    }
                }
            )
        ) {
            let children = model.loadChildren(at: item.path)
            ForEach(children) { child in
                DirectoryTreeRow(
                    item: child,
                    model: model,
                    onChangeDirectory: onChangeDirectory
                )
            }
        } label: {
            Label(item.name, systemImage: "folder.fill")
                .font(.system(size: 12))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .accentColor : .primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedPath = item.path }
                .gesture(TapGesture(count: 2).onEnded {
                    model.selectedPath = item.path
                    onChangeDirectory?(item.path)
                })
        }
        .id(item.path)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
                : nil
        )
    }
}

import Foundation

struct CommandItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String = "", command: String = "") {
        self.id = id
        self.name = name
        self.command = command
    }
}

class CommandStore: ObservableObject {
    @Published var commands: [CommandItem] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacTerminal")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("commands.json")
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            commands = try JSONDecoder().decode([CommandItem].self, from: data)
        } catch {
            print("Failed to load commands: \(error)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(commands)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save commands: \(error)")
        }
    }

    func add(_ item: CommandItem) {
        commands.append(item)
        save()
    }

    func update(_ item: CommandItem) {
        if let idx = commands.firstIndex(where: { $0.id == item.id }) {
            commands[idx] = item
            save()
        }
    }

    func delete(id: UUID) {
        commands.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        commands.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }
}

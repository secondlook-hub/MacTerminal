import Foundation

struct SSHBookmark: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var sshKeyPath: String?

    init(id: UUID = UUID(), name: String = "", host: String = "", port: Int = 22,
         username: String = "", password: String = "", sshKeyPath: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.sshKeyPath = sshKeyPath
    }
}

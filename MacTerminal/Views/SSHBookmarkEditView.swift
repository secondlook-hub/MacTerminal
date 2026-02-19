import SwiftUI

struct SSHBookmarkEditView: View {
    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var showPassword = false

    private let existingBookmark: SSHBookmark?
    private let onSave: (SSHBookmark) -> Void

    init(bookmark: SSHBookmark?, onSave: @escaping (SSHBookmark) -> Void) {
        self.existingBookmark = bookmark
        self.onSave = onSave
        _name = State(initialValue: bookmark?.name ?? "")
        _host = State(initialValue: bookmark?.host ?? "")
        _port = State(initialValue: String(bookmark?.port ?? 22))
        _username = State(initialValue: bookmark?.username ?? "")
        _password = State(initialValue: bookmark?.password ?? "")
    }

    var isValid: Bool {
        !name.isEmpty && !host.isEmpty && !username.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(existingBookmark == nil ? "New SSH Connection" : "Edit SSH Connection")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section("General") {
                    TextField("Display Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Connection") {
                    TextField("Host (IP or Hostname)", text: $host)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Authentication") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 420, height: 420)
    }

    private func save() {
        let bookmark = SSHBookmark(
            id: existingBookmark?.id ?? UUID(),
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            password: password
        )
        onSave(bookmark)
        dismiss()
    }

}

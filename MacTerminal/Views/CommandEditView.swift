import SwiftUI

struct CommandEditView: View {
    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var command: String

    private let existingCommand: CommandItem?
    private let onSave: (CommandItem) -> Void

    init(command: CommandItem?, onSave: @escaping (CommandItem) -> Void) {
        self.existingCommand = command
        self.onSave = onSave
        _name = State(initialValue: command?.name ?? "")
        _command = State(initialValue: command?.command ?? "")
    }

    var isValid: Bool {
        !name.isEmpty && !command.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existingCommand == nil ? "New Command" : "Edit Command")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section("General") {
                    TextField("Display Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                Section("Command") {
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 420, height: 340)
    }

    private func save() {
        let item = CommandItem(
            id: existingCommand?.id ?? UUID(),
            name: name,
            command: command
        )
        onSave(item)
        dismiss()
    }
}

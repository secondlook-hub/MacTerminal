import Foundation
import AppKit

/// One-click in-app update: downloads the release DMG, mounts it, swaps the
/// running app bundle for the new one, and relaunches. Replaces the manual
/// "download → mount → drag to Applications" dance.
///
/// The running binary stays alive during the swap (macOS keeps the mapped
/// inode), so it's safe to remove + re-copy the bundle and then launch the
/// fresh copy before terminating this process.
@MainActor
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    private init() {}

    private var panel: UpdateProgressPanel?

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func install(from downloadURL: URL, version: String) {
        guard panel == nil else { return }  // already installing
        let panel = UpdateProgressPanel(title: "Updating to MacTerminal \(version)")
        self.panel = panel
        panel.show(status: "Downloading…")

        Task {
            do {
                try await performInstall(downloadURL: downloadURL, panel: panel)
                // performInstall relaunches + terminates on success; reaching
                // here only happens if terminate was cancelled somehow.
            } catch {
                panel.close()
                self.panel = nil
                let alert = NSAlert()
                alert.messageText = "Update Failed"
                alert.informativeText = error.localizedDescription
                    + "\n\nYou can still install it manually from the download page."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Download Page")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
        }
    }

    private func performInstall(downloadURL: URL, panel: UpdateProgressPanel) async throws {
        // 1. Download the DMG.
        let (tempFile, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let dmg = tempFile.deletingLastPathComponent().appendingPathComponent("MacTerminal-update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: tempFile, to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }

        // 2. Mount it.
        panel.show(status: "Mounting disk image…")
        let attachOut = try await run("/usr/bin/hdiutil",
                                      ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard let mountPoint = Self.mountPoint(fromAttachPlist: attachOut) else {
            throw InstallError(message: "Could not mount the disk image.")
        }
        // Error paths detach via this defer; the success path detaches
        // explicitly below (defer wouldn't run past NSApp.terminate).
        defer {
            Task.detached { _ = try? await Self.runDetached("/usr/bin/hdiutil", ["detach", mountPoint, "-force"]) }
        }

        // 3. Locate the app inside and copy it off the (read-only) image.
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
                .first(where: { $0.hasSuffix(".app") }) else {
            throw InstallError(message: "No app was found inside the disk image.")
        }
        panel.show(status: "Installing…")
        let mountedApp = "\(mountPoint)/\(appName)"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTerminal-update-\(UUID().uuidString).app").path
        _ = try await run("/usr/bin/ditto", [mountedApp, staging])
        // The image is no longer needed once the copy is staged.
        _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
        // Downloaded bundles can carry quarantine; strip it so Gatekeeper
        // doesn't re-flag an app the user already approved. Best-effort.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging])

        // 4. Swap the installed bundle.
        let dest = Bundle.main.bundleURL.path
        _ = try await run("/bin/rm", ["-rf", dest])
        _ = try await run("/usr/bin/ditto", [staging, dest])
        _ = try? await run("/bin/rm", ["-rf", staging])

        // 5. Relaunch the new copy, then quit this (old) process.
        panel.show(status: "Restarting…")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dest),
                                                     configuration: config)
        NSApp.terminate(nil)
    }

    // MARK: - Process helpers

    /// Runs a command off the main thread, throwing with stderr on nonzero exit.
    private func run(_ launchPath: String, _ args: [String]) async throws -> String {
        try await Self.runDetached(launchPath, args)
    }

    private nonisolated static func runDetached(_ launchPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: launchPath)
                task.arguments = args
                let out = Pipe(), err = Pipe()
                task.standardOutput = out
                task.standardError = err
                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: InstallError(
                        message: detail.isEmpty
                            ? "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed (exit \(task.terminationStatus))"
                            : detail))
                } else {
                    continuation.resume(returning: stdout)
                }
            }
        }
    }

    /// Extracts the mount point from `hdiutil attach -plist` output.
    private nonisolated static func mountPoint(fromAttachPlist output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mount = entity["mount-point"] as? String { return mount }
        }
        return nil
    }
}

// MARK: - Progress panel

@MainActor
private final class UpdateProgressPanel {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                        styleMask: [.titled, .utilityWindow],
                        backing: .buffered, defer: true)
        panel.title = title
        panel.isFloatingPanel = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        panel.contentView = stack
        panel.center()
    }

    func show(status: String) {
        statusLabel.stringValue = status
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

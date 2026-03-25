import AppKit
import SwiftUI

@MainActor
final class LogViewerWindowController: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var logModels: [String: LogViewModel] = [:]

    func showLog(for projectName: String) {
        if let existingWindow = windows[projectName], existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let sanitizedName = sanitize(projectName)
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl/logs/\(sanitizedName).log")

        let model = LogViewModel(projectName: projectName, logFileURL: logURL)
        logModels[projectName] = model

        let view = LogViewerView(model: model, onClose: { [weak self] in
            self?.closeWindow(for: projectName)
        })

        let hosting = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "\(projectName) - 로그"
        newWindow.contentViewController = hosting
        newWindow.delegate = self
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating
        newWindow.minSize = NSSize(width: 400, height: 300)
        newWindow.center()
        newWindow.identifier = NSUserInterfaceItemIdentifier("log-\(projectName)")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        windows[projectName] = newWindow

        model.startTailing()
    }

    private func closeWindow(for projectName: String) {
        guard let window = windows[projectName] else { return }
        cleanupWindow(for: projectName)
        window.contentViewController = nil
        window.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let closedWindow = notification.object as? NSWindow,
                  let identifier = closedWindow.identifier?.rawValue,
                  identifier.hasPrefix("log-") else { return }
            let projectName = String(identifier.dropFirst(4))
            self?.cleanupWindow(for: projectName)
        }
    }

    private func cleanupWindow(for projectName: String) {
        guard let model = logModels.removeValue(forKey: projectName) else { return }
        model.stopTailing()
        windows.removeValue(forKey: projectName)
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

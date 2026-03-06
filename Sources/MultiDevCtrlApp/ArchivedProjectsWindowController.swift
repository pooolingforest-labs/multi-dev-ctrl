import AppKit
import SwiftUI

@MainActor
final class ArchivedProjectsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(configStore: ConfigStore) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        configStore.reload()

        let view = ArchivedProjectsView(
            configStore: configStore,
            onClose: { [weak self] in
                self?.closeWindow()
            }
        )

        let hosting = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "비활성 프로젝트 관리"
        newWindow.contentViewController = hosting
        newWindow.delegate = self
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating
        newWindow.center()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }

    func closeWindow() {
        guard let window else { return }
        window.contentViewController = nil
        window.close()

        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.window = nil
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            NSApp.setActivationPolicy(.accessory)
            self?.window = nil
        }
    }
}

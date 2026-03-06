import AppKit
import SwiftUI

@MainActor
final class AddProjectWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var state: AddProjectState?
    private weak var configStore: ConfigStore?

    func showAddProject(configStore: ConfigStore) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        configStore.reload()
        let existingGroups = configStore.existingGroups

        let newState = AddProjectState()
        newState.initializeGroupSelection(existingGroups: existingGroups)
        state = newState
        self.configStore = configStore

        let view = AddProjectView(
            state: newState,
            existingGroups: existingGroups,
            onAdd: { [weak self] projectDict in
                self?.configStore?.addProject(projectDict)
                self?.closeWindow()
            },
            onCancel: { [weak self] in
                self?.closeWindow()
            }
        )

        let hosting = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "프로젝트 추가"
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

    func showEditProject(project: ProjectConfig, configStore: ConfigStore) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        configStore.reload()
        let existingGroups = configStore.existingGroups

        let newState = AddProjectState()
        newState.loadFrom(project: project)
        newState.restoreExistingGroupSelectionIfNeeded(existingGroups: existingGroups)
        state = newState
        self.configStore = configStore

        let view = AddProjectView(
            state: newState,
            existingGroups: existingGroups,
            onAdd: { [weak self] projectDict in
                self?.configStore?.updateProject(named: project.name, with: projectDict)
                self?.closeWindow()
            },
            onCancel: { [weak self] in
                self?.closeWindow()
            }
        )

        let hosting = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "프로젝트 수정"
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
        guard let w = window else { return }
        w.contentViewController = nil
        w.close()

        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.window = nil
            self?.state = nil
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            NSApp.setActivationPolicy(.accessory)
            self?.window = nil
            self?.state = nil
        }
    }
}

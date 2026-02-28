import AppKit
import Foundation
import SwiftUI

struct AppConfig: Decodable {
    let projects: [ProjectConfig]
}

struct ProjectConfig: Decodable, Identifiable {
    let name: String
    let path: String
    let actions: [ProjectAction]

    var id: String { name }

    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }
}

struct ProjectAction: Decodable {
    let type: ActionType
    let command: String?
    let commands: [String]?
    let appName: String?
}

enum ActionType: String, Decodable {
    case runCommand
    case openIterm
    case openItermSplit
    case openApp
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var projects: [ProjectConfig] = []
    @Published private(set) var statusMessage: String?

    private let fileManager = FileManager.default

    var configPaths: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".multi-dev-ctrl/projects.json"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("config/projects.json")
        ]
    }

    func reload() {
        do {
            let configURL = try findConfigURL()
            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            projects = decoded.projects
            statusMessage = "Loaded \(decoded.projects.count) projects from \(configURL.path)"
        } catch {
            projects = []
            statusMessage = "Config load failed: \(error.localizedDescription)"
        }
    }

    func openConfigFolder() {
        let folderURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".multi-dev-ctrl", isDirectory: true)

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folderURL)
            statusMessage = "Opened \(folderURL.path)"
        } catch {
            statusMessage = "Unable to open config folder: \(error.localizedDescription)"
        }
    }

    private func findConfigURL() throws -> URL {
        for path in configPaths where fileManager.fileExists(atPath: path.path) {
            return path
        }

        throw NSError(
            domain: "ConfigStore",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "No config file found. Create ~/.multi-dev-ctrl/projects.json"
            ]
        )
    }
}

private struct ManagedProcess {
    let id: UUID
    let process: Process
    let logFileHandle: FileHandle?
}

@MainActor
final class ProjectRunner: ObservableObject {
    @Published private(set) var runningProjects: Set<String> = []
    @Published private(set) var statusMessage: String?

    private let fileManager = FileManager.default
    private var processesByProject: [String: [ManagedProcess]] = [:]

    private var logsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    func run(_ project: ProjectConfig) {
        stop(projectName: project.name, silent: true)

        var startedBackgroundProcess = false

        for action in project.actions {
            switch action.type {
            case .runCommand:
                guard let command = action.command, !command.isEmpty else {
                    statusMessage = "\(project.name): runCommand requires a command"
                    continue
                }

                do {
                    try launchBackgroundCommand(projectName: project.name, path: project.expandedPath, command: command)
                    startedBackgroundProcess = true
                } catch {
                    statusMessage = "\(project.name): command failed to start (\(error.localizedDescription))"
                }

            case .openIterm:
                let command = action.command
                if openInIterm(path: project.expandedPath, command: command) {
                    statusMessage = "\(project.name): opened iTerm"
                } else {
                    statusMessage = "\(project.name): failed to open iTerm"
                }

            case .openItermSplit:
                let commands = normalizedCommands(action.commands)
                guard commands.count >= 2 else {
                    statusMessage = "\(project.name): openItermSplit requires at least 2 commands"
                    continue
                }

                if openInItermSplit(path: project.expandedPath, commands: commands) {
                    statusMessage = "\(project.name): opened iTerm split"
                } else {
                    statusMessage = "\(project.name): failed to open iTerm split"
                }

            case .openApp:
                guard let appName = action.appName, !appName.isEmpty else {
                    statusMessage = "\(project.name): openApp requires appName"
                    continue
                }

                if openApplication(named: appName) {
                    statusMessage = "\(project.name): opened \(appName)"
                } else {
                    statusMessage = "\(project.name): failed to open \(appName)"
                }
            }
        }

        if startedBackgroundProcess {
            runningProjects.insert(project.name)
            statusMessage = "\(project.name): setup launched"
        }
    }

    func stop(projectName: String, silent: Bool = false) {
        guard let managedProcesses = processesByProject.removeValue(forKey: projectName) else {
            return
        }

        for entry in managedProcesses {
            if entry.process.isRunning {
                entry.process.terminate()
            }
            entry.logFileHandle?.closeFile()
        }

        runningProjects.remove(projectName)

        if !silent {
            statusMessage = "\(projectName): stopped"
        }
    }

    private func launchBackgroundCommand(projectName: String, path: String, command: String) throws {
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let logURL = logsDirectory.appendingPathComponent("\(sanitize(projectName)).log")

        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "cd \(shellEscape(path)) && \(command)"]
        process.standardOutput = handle
        process.standardError = handle

        let id = UUID()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.removeProcess(projectName: projectName, id: id)
            }
        }

        try process.run()

        let managed = ManagedProcess(id: id, process: process, logFileHandle: handle)
        processesByProject[projectName, default: []].append(managed)
    }

    private func removeProcess(projectName: String, id: UUID) {
        guard var managedProcesses = processesByProject[projectName] else {
            return
        }

        guard let idx = managedProcesses.firstIndex(where: { $0.id == id }) else {
            return
        }

        managedProcesses[idx].logFileHandle?.closeFile()
        managedProcesses.remove(at: idx)

        if managedProcesses.isEmpty {
            processesByProject.removeValue(forKey: projectName)
            runningProjects.remove(projectName)
            statusMessage = "\(projectName): process exited"
        } else {
            processesByProject[projectName] = managedProcesses
        }
    }

    private func openApplication(named appName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func openInIterm(path: String, command: String?) -> Bool {
        guard let command, !command.isEmpty else {
            if openApplicationWithPath(appName: "iTerm", path: path) {
                return true
            }

            return openApplicationWithPath(appName: "Terminal", path: path)
        }

        let joinedCommand = "cd \(shellEscape(path)); \(command)"
        let appleScriptCommand = escapeForAppleScript(joinedCommand)

        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current window
                create tab with default profile
                tell current session
                    write text "\(appleScriptCommand)"
                end tell
            end tell
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                return true
            }
        }

        return runTerminalFallback(path: path, command: command)
    }

    private func openInItermSplit(path: String, commands: [String]) -> Bool {
        let commandA = escapeForAppleScript("cd \(shellEscape(path)); \(commands[0])")
        let commandB = escapeForAppleScript("cd \(shellEscape(path)); \(commands[1])")

        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "\(commandA)"
                    set splitSession to (split vertically with default profile)
                end tell
                tell splitSession
                    write text "\(commandB)"
                end tell
            end tell
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return false
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error == nil
    }

    private func openApplicationWithPath(appName: String, path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runTerminalFallback(path: String, command: String) -> Bool {
        let terminalCommand = escapeForAppleScript("cd \(shellEscape(path)); \(command)")
        let script = """
        tell application "Terminal"
            activate
            do script "\(terminalCommand)"
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return false
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error == nil
    }

    private func normalizedCommands(_ commands: [String]?) -> [String] {
        guard let commands else {
            return []
        }

        return commands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct MenuContentView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var runner: ProjectRunner

    var body: some View {
        if configStore.projects.isEmpty {
            Text("No projects")
        } else {
            ForEach(configStore.projects) { project in
                Button {
                    runner.run(project)
                } label: {
                    if runner.runningProjects.contains(project.name) {
                        Label(project.name, systemImage: "bolt.fill")
                    } else {
                        Label(project.name, systemImage: "play")
                    }
                }

                if runner.runningProjects.contains(project.name) {
                    Button("Stop \(project.name)") {
                        runner.stop(projectName: project.name)
                    }
                }
            }
        }

        Divider()

        Button("Reload Config") {
            configStore.reload()
        }

        Button("Open Config Folder") {
            configStore.openConfigFolder()
        }

        if let message = runner.statusMessage ?? configStore.statusMessage {
            Divider()
            Text(message)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
struct MultiDevCtrlApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var runner = ProjectRunner()

    var body: some Scene {
        MenuBarExtra("Dev Ctrl", systemImage: "terminal") {
            MenuContentView(configStore: configStore, runner: runner)
                .onAppear {
                    configStore.reload()
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

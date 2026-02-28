import AppKit
import Foundation
import SwiftUI

struct AppConfig: Decodable {
    let projects: [ProjectConfig]
}

struct ProjectConfig: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let actions: [ProjectAction]

    var id: String { name }

    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }
}

struct ProjectAction: Decodable, Equatable {
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

enum GitCommitState {
    case latest
    case needsCommit

    var marker: String {
        switch self {
        case .latest:
            return "🟢"
        case .needsCommit:
            return "🟠"
        }
    }

    var description: String {
        switch self {
        case .latest:
            return "Latest commit state"
        case .needsCommit:
            return "Uncommitted changes or not on latest commit"
        }
    }
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

final class GitStatusStore: ObservableObject {
    @Published private(set) var states: [String: GitCommitState] = [:]

    func refresh(projects: [ProjectConfig]) {
        let snapshot = projects.map { (name: $0.name, path: $0.expandedPath) }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var nextStates: [String: GitCommitState] = [:]

            for project in snapshot {
                nextStates[project.name] = Self.resolveCommitState(path: project.path)
            }

            DispatchQueue.main.async {
                self?.states = nextStates
            }
        }
    }

    func state(for project: ProjectConfig) -> GitCommitState {
        states[project.name] ?? .needsCommit
    }

    private static func resolveCommitState(path: String) -> GitCommitState {
        let inWorkTree = runGitCommand(["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
        guard inWorkTree else {
            return .needsCommit
        }

        let dirtyState = runGitCommand(["-C", path, "status", "--porcelain"]) ?? ""
        if !dirtyState.isEmpty {
            return .needsCommit
        }

        let head = runGitCommand(["-C", path, "rev-parse", "HEAD"]) ?? ""
        guard !head.isEmpty else {
            return .needsCommit
        }

        let upstream = runGitCommand(["-C", path, "rev-parse", "--verify", "--quiet", "@{u}"])
        guard let upstream, !upstream.isEmpty else {
            return .latest
        }

        return head == upstream ? .latest : .needsCommit
    }

    private static func runGitCommand(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    private var terminalWindowIDsByProject: [String: Int] = [:]

    private var logsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    func run(_ project: ProjectConfig) {
        let hasRunningProcess = hasRunningProcesses(projectName: project.name)

        if hasRunningProcess || hasTerminalAction(project: project) {
            if focusExistingWindow(for: project) {
                statusMessage = "\(project.name): already running, focused window"
                return
            }

            if hasRunningProcess {
                statusMessage = "\(project.name): already running"
                return
            }
        }

        var startedBackgroundProcess = false
        let projectMarker = markerForProject(project.name)
        let projectTitle = project.name

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
                if let windowID = openInIterm(path: project.expandedPath, command: command, marker: projectMarker, title: projectTitle) {
                    if windowID > 0 {
                        terminalWindowIDsByProject[project.name] = windowID
                    }
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

                if let windowID = openInItermSplit(path: project.expandedPath, commands: commands, marker: projectMarker, title: projectTitle) {
                    if windowID > 0 {
                        terminalWindowIDsByProject[project.name] = windowID
                    }
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

    private func hasRunningProcesses(projectName: String) -> Bool {
        guard let managedProcesses = processesByProject[projectName] else {
            return false
        }

        return managedProcesses.contains(where: { $0.process.isRunning })
    }

    private func hasTerminalAction(project: ProjectConfig) -> Bool {
        project.actions.contains(where: { $0.type == .openIterm || $0.type == .openItermSplit })
    }

    private func markerForProject(_ projectName: String) -> String {
        projectName
    }

    private func focusExistingWindow(for project: ProjectConfig) -> Bool {
        if hasTerminalAction(project: project) {
            if let windowID = terminalWindowIDsByProject[project.name], focusItermWindow(windowID: windowID) {
                return true
            }

            if focusItermSession(marker: markerForProject(project.name)) {
                return true
            }
        }

        if let appName = project.actions.first(where: { $0.type == .openApp })?.appName, !appName.isEmpty {
            return openApplication(named: appName)
        }

        return false
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

    private func focusItermSession(marker: String) -> Bool {
        let escapedMarker = escapeForAppleScript(marker)
        let script = """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (name of s as text) is "\(escapedMarker)" then
                            tell w
                                set current tab to t
                            end tell
                            set current window to w
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return false
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else {
            return false
        }

        if let stringValue = result.stringValue {
            return stringValue.lowercased() == "true"
        }

        return result.booleanValue
    }

    private func focusItermWindow(windowID: Int) -> Bool {
        let script = """
        tell application "iTerm"
            activate
            try
                set targetWindow to (first window whose id is \(windowID))
                set current window to targetWindow
                return true
            on error
                return false
            end try
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return false
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else {
            return false
        }

        if let stringValue = result.stringValue {
            return stringValue.lowercased() == "true"
        }

        return result.booleanValue
    }

    private func openInIterm(path: String, command: String?, marker: String, title: String) -> Int? {
        let joinedCommand = buildItermCommand(path: path, command: command, title: title)

        let appleScriptCommand = escapeForAppleScript(joinedCommand)
        let escapedMarker = escapeForAppleScript(marker)

        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                set name to "\(escapedMarker)"
                write text "\(appleScriptCommand)"
            end tell
            return id of newWindow
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                if let parsed = parseIntValue(result) {
                    return parsed
                }
            }
        }

        guard let command, !command.isEmpty else {
            if openApplicationWithPath(appName: "Terminal", path: path) {
                return -1
            }
            return nil
        }

        if runTerminalFallback(path: path, command: command) {
            return -1
        }
        return nil
    }

    private func openInItermSplit(path: String, commands: [String], marker: String, title: String) -> Int? {
        let commandA = escapeForAppleScript(buildItermCommand(path: path, command: commands[0], title: title))
        let commandB = escapeForAppleScript(buildItermCommand(path: path, command: commands[1], title: title))
        let escapedMarker = escapeForAppleScript(marker)

        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                set name to "\(escapedMarker)"
                write text "\(commandA)"
                set splitSession to (split vertically with default profile)
                tell splitSession
                    set name to "\(escapedMarker)"
                    write text "\(commandB)"
                end tell
            end tell
            return id of newWindow
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else {
            return nil
        }

        return parseIntValue(result)
    }

    private func buildItermCommand(path: String, command: String?, title: String) -> String {
        let titleCommand = "printf '\\033]1;%s\\007\\033]2;%s\\007' \(shellEscape(title)) \(shellEscape(title))"
        var parts: [String] = [
            "cd \(shellEscape(path))",
            "export DISABLE_AUTO_TITLE=true",
            titleCommand
        ]

        if let command, !command.isEmpty {
            parts.append("(while true; do \(titleCommand); sleep 1; done) & _mdc_title_pid=$!")
            parts.append("trap 'kill $_mdc_title_pid 2>/dev/null' EXIT INT TERM")
            parts.append(command)
        }

        return parts.joined(separator: "; ")
    }

    private func parseIntValue(_ descriptor: NSAppleEventDescriptor) -> Int? {
        if let stringValue = descriptor.stringValue, let parsed = Int(stringValue) {
            return parsed
        }

        let parsed = Int(descriptor.int32Value)
        return parsed == 0 ? nil : parsed
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
    @ObservedObject var gitStore: GitStatusStore

    var body: some View {
        if configStore.projects.isEmpty {
            Text("No projects")
        } else {
            ForEach(configStore.projects) { project in
                Button {
                    runner.run(project)
                } label: {
                    let state = gitStore.state(for: project)
                    Label("\(project.name) \(state.marker)", systemImage: runner.runningProjects.contains(project.name) ? "bolt.fill" : "play")
                }
                .help(gitStore.state(for: project).description)

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
            gitStore.refresh(projects: configStore.projects)
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
    @StateObject private var gitStore = GitStatusStore()

    var body: some Scene {
        MenuBarExtra("Dev Ctrl", systemImage: "terminal") {
            MenuContentView(configStore: configStore, runner: runner, gitStore: gitStore)
                .onAppear {
                    configStore.reload()
                    gitStore.refresh(projects: configStore.projects)
                }
                .onChange(of: configStore.projects) { projects in
                    gitStore.refresh(projects: projects)
                }
        }
        .menuBarExtraStyle(.menu)
    }
}

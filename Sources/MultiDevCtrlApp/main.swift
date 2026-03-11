import AppKit
import Foundation
import SwiftUI

enum ItermMode: String, Codable {
    case window
    case tab
}

enum EditorType: String, Codable, CaseIterable {
    case vscode = "vscode"
    case cursor = "cursor"
    case antigravity = "antigravity"

    var appName: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }

    var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }
}

enum ProjectType: String, Codable, CaseIterable, Identifiable {
    case client
    case server

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .client: return "Client"
        case .server: return "Server"
        }
    }
}

struct AppConfig: Codable {
    let projects: [ProjectConfig]
    var itermMode: ItermMode?
    var editor: EditorType?
}

struct ProjectConfig: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let projectType: ProjectType
    let port: Int?
    let actions: [ProjectAction]
    let group: String?
    let stopCommand: String?
    let isEnabled: Bool
    let springProfile: String?
    var id: String { name }

    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    enum CodingKeys: String, CodingKey {
        case name, path, projectType, port, actions, group, stopCommand, isEnabled, springProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        projectType = try container.decodeIfPresent(ProjectType.self, forKey: .projectType) ?? .client
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        actions = try container.decode([ProjectAction].self, forKey: .actions)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        stopCommand = try container.decodeIfPresent(String.self, forKey: .stopCommand)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        springProfile = try container.decodeIfPresent(String.self, forKey: .springProfile)
    }
}

struct ProjectAction: Codable, Equatable {
    let type: ActionType
    let command: String?
    let commands: [String]?
    let appName: String?
}

enum ActionType: String, Codable {
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
            return "✓"
        case .needsCommit:
            return "✗"
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
    @Published var statusMessage: String?
    @Published var itermMode: ItermMode = .window
    @Published var editor: EditorType = .cursor

    let fileManager = FileManager.default
    var currentConfigURL: URL?

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
            currentConfigURL = configURL
            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            projects = decoded.projects
            itermMode = decoded.itermMode ?? .window
            editor = decoded.editor ?? .cursor
            statusMessage = "Loaded \(decoded.projects.count) projects from \(configURL.path)"
        } catch {
            projects = []
            statusMessage = "Config load failed: \(error.localizedDescription)"
        }
    }

    func setItermMode(_ mode: ItermMode) {
        guard let configURL = currentConfigURL else { return }
        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            json["itermMode"] = mode.rawValue
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            itermMode = mode
            statusMessage = "iTerm 모드: \(mode == .tab ? "탭" : "윈도우")"
        } catch {
            statusMessage = "설정 저장 실패: \(error.localizedDescription)"
        }
    }

    func setEditor(_ editor: EditorType) {
        guard let configURL = currentConfigURL else { return }
        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            json["editor"] = editor.rawValue
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            self.editor = editor
            statusMessage = "에디터: \(editor.displayName)"
        } catch {
            statusMessage = "설정 저장 실패: \(error.localizedDescription)"
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

@MainActor
final class PortStatusStore: ObservableObject {
    @Published private(set) var listeningPorts: Set<Int> = []
    private var timer: Timer?

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func isPortListening(_ port: Int) -> Bool {
        listeningPorts.contains(port)
    }

    func forceRefresh() {
        refresh()
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listening = Self.checkListeningPorts()
            DispatchQueue.main.async {
                self?.listeningPorts = listening
            }
        }
    }

    nonisolated private static func checkListeningPorts() -> Set<Int> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-nP", "-Fn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            // lsof -Fn outputs lines like "n*:3000" or "n127.0.0.1:3000"
            guard line.hasPrefix("n") else { continue }
            if let colonIdx = line.lastIndex(of: ":") {
                let portStr = line[line.index(after: colonIdx)...]
                if let port = Int(portStr) {
                    ports.insert(port)
                }
            }
        }
        return ports
    }
}

private struct ManagedProcess {
    let id: UUID
    let process: Process
    let logFileHandle: FileHandle?
}

private struct ClaudeTargetProject {
    let name: String
    let path: String
    let isNextJS: Bool
}

private enum StopCommandResult {
    case notConfigured
    case succeeded
    case failed
}

private enum NodePackageManager {
    case npm
    case pnpm
    case yarn
    case bun

    var installCommand: String {
        switch self {
        case .npm:
            return "npm install"
        case .pnpm:
            return "pnpm install"
        case .yarn:
            return "yarn install"
        case .bun:
            return "bun install"
        }
    }
}

@MainActor
final class ProjectRunner: ObservableObject {
    @Published private(set) var runningProjects: Set<String> = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBulkCommitRunning = false
    @Published private(set) var commitPushProjectsLaunching: Set<String> = []

    private let fileManager = FileManager.default
    private var processesByProject: [String: [ManagedProcess]] = [:]
    private var terminalWindowIDsByProject: [String: Int] = [:]
    private var dependencyInstallInProgressProjects: Set<String> = []
    private var runtimePortsByProject: [String: Int] = [:]
    private let fallbackPortStart = 3000

    private enum PortResolution {
        case resolved(port: Int, preferred: Int?, wasReassigned: Bool)
        case failed(message: String)
    }

    func runtimePort(for project: ProjectConfig) -> Int? {
        runtimePortsByProject[project.name]
    }

    func port(for project: ProjectConfig, in _: [ProjectConfig]) -> Int? {
        if let runtimePort = runtimePortsByProject[project.name] {
            return runtimePort
        }

        if project.projectType == .server {
            return project.port
        }

        return preferredPortForProject(project)
    }

    private var logsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    private func projectRequiresRuntimePort(_ project: ProjectConfig) -> Bool {
        project.actions.contains { $0.type != .openApp } || (project.stopCommand?.contains("$PORT") ?? false)
    }

    private func resolvePortForRun(_ project: ProjectConfig) -> PortResolution {
        if project.projectType == .server {
            guard let configuredPort = project.port, isValidPort(configuredPort) else {
                runtimePortsByProject.removeValue(forKey: project.name)
                return .failed(message: "\(project.name): server 프로젝트는 고정 포트 입력이 필요합니다")
            }

            let unavailable = unavailablePorts(excludingProjectName: project.name)
            guard !unavailable.contains(configuredPort) else {
                runtimePortsByProject.removeValue(forKey: project.name)
                return .failed(message: "\(project.name): 서버 포트 \(configuredPort)가 이미 사용 중입니다")
            }

            runtimePortsByProject[project.name] = configuredPort
            return .resolved(port: configuredPort, preferred: configuredPort, wasReassigned: false)
        }

        let preferred = preferredPortForProject(project)
        let unavailable = unavailablePorts(excludingProjectName: project.name)

        if let preferred, !unavailable.contains(preferred) {
            runtimePortsByProject[project.name] = preferred
            return .resolved(port: preferred, preferred: preferred, wasReassigned: false)
        }

        if let existing = runtimePortsByProject[project.name], !unavailable.contains(existing) {
            return .resolved(port: existing, preferred: preferred, wasReassigned: false)
        }

        let start = max(
            fallbackPortStart,
            (preferred ?? runtimePortsByProject[project.name] ?? fallbackPortStart) + (preferred == nil ? 0 : 1)
        )

        let selected = findAvailablePort(startingAt: start, unavailable: unavailable)
            ?? findAvailablePort(startingAt: fallbackPortStart, unavailable: unavailable)
            ?? (preferred ?? fallbackPortStart)

        runtimePortsByProject[project.name] = selected
        return .resolved(port: selected, preferred: preferred, wasReassigned: preferred != nil && preferred != selected)
    }

    private func unavailablePorts(excludingProjectName: String? = nil) -> Set<Int> {
        var ports = checkListeningPorts()

        for (projectName, port) in runtimePortsByProject where projectName != excludingProjectName {
            ports.insert(port)
        }

        return ports
    }

    private func findAvailablePort(startingAt startPort: Int, unavailable: Set<Int>) -> Int? {
        let minPort = 1024
        let maxPort = 65535
        let start = min(max(startPort, minPort), maxPort)

        if start <= maxPort {
            for port in start...maxPort where !unavailable.contains(port) {
                return port
            }
        }

        if minPort < start {
            for port in minPort..<(start) where !unavailable.contains(port) {
                return port
            }
        }

        return nil
    }

    func run(_ project: ProjectConfig, allProjects _: [ProjectConfig], itermMode: ItermMode = .window) {
        guard project.isEnabled else {
            statusMessage = "\(project.name): 비활성 프로젝트라 실행하지 않습니다"
            return
        }

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

        if dependencyInstallInProgressProjects.contains(project.name) {
            statusMessage = "\(project.name): 패키지 설치 진행 중입니다"
            return
        }

        let runtimePort: Int?
        if projectRequiresRuntimePort(project) {
            switch resolvePortForRun(project) {
            case let .resolved(port, preferred, wasReassigned):
                runtimePort = port
                if wasReassigned, let preferred {
                    statusMessage = "\(project.name): \(preferred) 포트가 사용 중이라 \(port)로 실행합니다"
                }
            case let .failed(message):
                statusMessage = message
                return
            }
        } else {
            runtimePort = nil
        }

        autoInstallDependenciesIfNeeded(project: project, runtimePort: runtimePort) { [weak self] installSuccess in
            guard let self else { return }
            guard installSuccess else {
                self.runtimePortsByProject.removeValue(forKey: project.name)
                return
            }
            self.executeProjectActions(project, runtimePort: runtimePort, itermMode: itermMode)
        }
    }

    private func executeProjectActions(_ project: ProjectConfig, runtimePort: Int?, itermMode: ItermMode) {
        var startedBackgroundProcess = false
        let projectMarker = markerForProject(project.name)
        let projectTitle = project.name

        for action in project.actions {
            switch action.type {
            case .runCommand:
                guard var command = action.command, !command.isEmpty else {
                    statusMessage = "\(project.name): runCommand requires a command"
                    continue
                }
                if let runtimePort {
                    command = commandWithRuntimePort(command, runtimePort: runtimePort)
                }
                command = commandWithSpringProfile(command, project: project)

                do {
                    try launchBackgroundCommand(projectName: project.name, path: project.expandedPath, command: command)
                    startedBackgroundProcess = true
                } catch {
                    statusMessage = "\(project.name): command failed to start (\(error.localizedDescription))"
                }

            case .openIterm:
                var command = action.command
                if let runtimePort, let rawCommand = command {
                    command = commandWithRuntimePort(rawCommand, runtimePort: runtimePort)
                }
                if let rawCommand = command {
                    command = commandWithSpringProfile(rawCommand, project: project)
                }
                if let windowID = openInIterm(path: project.expandedPath, command: command, marker: projectMarker, title: projectTitle, mode: itermMode) {
                    if windowID > 0 {
                        terminalWindowIDsByProject[project.name] = windowID
                    }
                    statusMessage = "\(project.name): opened iTerm"
                } else {
                    statusMessage = "\(project.name): failed to open iTerm"
                }

            case .openItermSplit:
                let commands = normalizedCommands(action.commands?.map {
                    var cmd = $0
                    if let runtimePort {
                        cmd = commandWithRuntimePort(cmd, runtimePort: runtimePort)
                    }
                    cmd = commandWithSpringProfile(cmd, project: project)
                    return cmd
                })
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

    private func autoInstallDependenciesIfNeeded(
        project: ProjectConfig,
        runtimePort: Int?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let installCommand = installCommandIfNeeded(project: project, runtimePort: runtimePort) else {
            completion(true)
            return
        }

        let projectName = project.name
        dependencyInstallInProgressProjects.insert(projectName)
        statusMessage = "\(projectName): 의존성 설치 중..."

        let projectPath = project.expandedPath
        DispatchQueue.global(qos: .utility).async {
            let success = Self.runShellCommand(path: projectPath, command: installCommand)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dependencyInstallInProgressProjects.remove(projectName)

                if success {
                    self.statusMessage = "\(projectName): 의존성 설치 완료"
                } else {
                    self.statusMessage = "\(projectName): 의존성 설치 실패"
                }

                completion(success)
            }
        }
    }

    private func installCommandIfNeeded(project: ProjectConfig, runtimePort: Int?) -> String? {
        let projectRoot = URL(fileURLWithPath: project.expandedPath, isDirectory: true)
        let packageJSONPath = projectRoot.appendingPathComponent("package.json").path
        guard fileManager.fileExists(atPath: packageJSONPath) else {
            return nil
        }

        let commands = commandsNeedingPreparation(project: project, runtimePort: runtimePort)
        guard commands.contains(where: shouldAutoInstallDependencies) else {
            return nil
        }

        return preferredNodePackageManager(for: commands, in: projectRoot).installCommand
    }

    private func commandsNeedingPreparation(project: ProjectConfig, runtimePort: Int?) -> [String] {
        var commands: [String] = []

        for action in project.actions {
            switch action.type {
            case .runCommand:
                if let command = action.command?
                    .replacingOccurrences(of: "$PORT", with: runtimePort.map(String.init) ?? "$PORT")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    commands.append(command)
                }
            case .openIterm:
                if let command = action.command?
                    .replacingOccurrences(of: "$PORT", with: runtimePort.map(String.init) ?? "$PORT")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    commands.append(command)
                }
            case .openItermSplit:
                let splitCommands = normalizedCommands(
                    action.commands?.map { $0.replacingOccurrences(of: "$PORT", with: runtimePort.map(String.init) ?? "$PORT") }
                )
                commands.append(contentsOf: splitCommands)
            case .openApp:
                continue
            }
        }

        return commands
    }

    private func commandWithRuntimePort(_ command: String, runtimePort: Int) -> String {
        var rewritten = replacePortPlaceholder(in: command, runtimePort: runtimePort)

        // Best-effort override for common explicit port flags when fallback ports are used.
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "(--port(?:\\s*=\\s*|\\s+))\\d{1,5}",
            with: "$1\(runtimePort)"
        )
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "((?:^|\\s)-p\\s*)\\d{1,5}(\\b)",
            with: "$1\(runtimePort)$2"
        )
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "((?:^|\\s)-p)\\d{1,5}(\\b)",
            with: "$1\(runtimePort)$2"
        )
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "((?:^|\\s)PORT\\s*=\\s*)\\d{1,5}(\\b)",
            with: "$1\(runtimePort)$2"
        )
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "(runserver(?:\\s+\\S+)?:)\\d{1,5}(\\b)",
            with: "$1\(runtimePort)$2"
        )
        rewritten = replacingRegex(
            in: rewritten,
            pattern: "(runserver\\s+)\\d{1,5}(\\b)",
            with: "$1\(runtimePort)$2"
        )

        if !containsRegex(in: rewritten, pattern: "(?:^|\\s)PORT\\s*=") {
            rewritten = "PORT=\(runtimePort) \(rewritten)"
        }

        return rewritten
    }

    private func commandWithSpringProfile(_ command: String, project: ProjectConfig) -> String {
        guard let profile = project.springProfile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty else {
            return command
        }

        // Gradle: ./gradlew bootRun → ./gradlew bootRun --args='--spring.profiles.active=dev'
        if command.contains("bootRun") {
            if command.contains("--args") {
                return command
            }
            return "\(command) --args='--spring.profiles.active=\(profile)'"
        }

        // Maven: ./mvnw spring-boot:run → ./mvnw spring-boot:run -Dspring-boot.run.profiles=dev
        if command.contains("spring-boot:run") {
            if command.contains("-Dspring-boot.run.profiles") || command.contains("-Dspring.profiles.active") {
                return command
            }
            return "\(command) -Dspring-boot.run.profiles=\(profile)"
        }

        return command
    }

    private func replacePortPlaceholder(in command: String, runtimePort: Int?) -> String {
        command.replacingOccurrences(of: "$PORT", with: runtimePort.map(String.init) ?? "$PORT")
    }

    private func preferredPortForProject(_ project: ProjectConfig) -> Int? {
        if project.projectType == .server {
            guard let configuredPort = project.port, isValidPort(configuredPort) else {
                return nil
            }

            return configuredPort
        }

        if let configuredPort = project.port, isValidPort(configuredPort) {
            return configuredPort
        }

        if let actionPort = firstPortFromProjectCommands(project) {
            return actionPort
        }

        if let envPort = portFromDotEnvFiles(projectRootPath: project.expandedPath) {
            return envPort
        }

        if let scriptPort = portFromPackageScripts(project) {
            return scriptPort
        }

        return nil
    }

    private func firstPortFromProjectCommands(_ project: ProjectConfig) -> Int? {
        for command in actionCommands(project.actions) {
            if let port = extractPort(from: command) {
                return port
            }
        }

        return nil
    }

    private func actionCommands(_ actions: [ProjectAction]) -> [String] {
        var commands: [String] = []

        for action in actions {
            switch action.type {
            case .runCommand, .openIterm:
                if let command = action.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty {
                    commands.append(command)
                }
            case .openItermSplit:
                commands.append(
                    contentsOf: normalizedCommands(action.commands?.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    })
                )
            case .openApp:
                continue
            }
        }

        return commands
    }

    private func portFromDotEnvFiles(projectRootPath: String) -> Int? {
        let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        let envFileNames = [
            ".env",
            ".env.local",
            ".env.development",
            ".env.development.local"
        ]

        for envFileName in envFileNames {
            let envFilePath = projectRoot.appendingPathComponent(envFileName).path
            guard fileManager.fileExists(atPath: envFilePath),
                  let content = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
                continue
            }

            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }

                if let value = firstMatch(in: trimmed, pattern: "^PORT\\s*=\\s*\"?(\\d{1,5})\"?$"),
                   let port = Int(value),
                   isValidPort(port) {
                    return port
                }
            }
        }

        return nil
    }

    private func portFromPackageScripts(_ project: ProjectConfig) -> Int? {
        let packageJSONPath = URL(fileURLWithPath: project.expandedPath, isDirectory: true)
            .appendingPathComponent("package.json")
            .path

        guard fileManager.fileExists(atPath: packageJSONPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: packageJSONPath)),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = decoded["scripts"] as? [String: String] else {
            return nil
        }

        for command in actionCommands(project.actions) {
            guard let scriptName = scriptNameFromRunCommand(command),
                  let script = scripts[scriptName],
                  let port = extractPort(from: script) else {
                continue
            }

            return port
        }

        return nil
    }

    private func scriptNameFromRunCommand(_ command: String) -> String? {
        let patterns = [
            "(?:^|\\s)npm\\s+run\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)pnpm\\s+run\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)pnpm\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)yarn\\s+run\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)yarn\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)bun\\s+run\\s+([\\w:-]+)(?:\\s|$)",
            "(?:^|\\s)bun\\s+([\\w:-]+)(?:\\s|$)"
        ]

        for pattern in patterns {
            guard let script = firstMatch(in: command, pattern: pattern) else {
                continue
            }

            if script.hasPrefix("-") {
                continue
            }

            return script
        }

        return nil
    }

    private func extractPort(from command: String) -> Int? {
        let patterns = [
            "(?:^|\\s)PORT\\s*=\\s*(\\d{1,5})(?:\\b|\\s|$)",
            "(?:--port|--http-port|--server-port|--listen-port|--dev-port|--bind-port)(?:\\s*=\\s*|\\s+)(\\d{1,5})(?:\\b|\\s|$)",
            "(?:^|\\s)-p\\s*(\\d{1,5})(?:\\b|\\s|$)",
            "(?:^|\\s)-p(\\d{1,5})(?:\\b|\\s|$)",
            "runserver(?:\\s+\\S+)?:(\\d{1,5})(?:\\b|\\s|$)",
            "runserver\\s+(\\d{1,5})(?:\\b|\\s|$)",
            "localhost:(\\d{1,5})(?:\\b|\\s|$)"
        ]

        for pattern in patterns {
            guard let match = firstMatch(in: command, pattern: pattern),
                  let port = Int(match),
                  isValidPort(port) else {
                continue
            }

            return port
        }

        return nil
    }

    private func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    private func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges > 1,
              let matchedRange = Range(match.range(at: 1), in: value) else {
            return nil
        }

        return String(value[matchedRange])
    }

    private func containsRegex(in value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private func replacingRegex(in value: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }

    private func checkListeningPorts() -> Set<Int> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-nP", "-Fn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("n"), let colonIdx = line.lastIndex(of: ":") else {
                continue
            }

            let portString = line[line.index(after: colonIdx)...]
            if let port = Int(portString), isValidPort(port) {
                ports.insert(port)
            }
        }

        return ports
    }

    private func shouldAutoInstallDependencies(command: String) -> Bool {
        let lower = command.lowercased()

        let installPatterns = [
            "npm install",
            "npm ci",
            "pnpm install",
            "pnpm i",
            "yarn install",
            "yarn --immutable",
            "bun install"
        ]
        if installPatterns.contains(where: { lower.contains($0) }) {
            return false
        }

        let runPatterns = [
            "npm run",
            "npm start",
            "pnpm run",
            "pnpm start",
            "pnpm dev",
            "yarn run",
            "yarn start",
            "yarn dev",
            "bun run",
            "bun dev"
        ]
        if runPatterns.contains(where: { lower.contains($0) }) {
            return true
        }

        return lower.contains("npm ") || lower.contains("pnpm ") || lower.contains("yarn ") || lower.contains("bun ")
    }

    private func preferredNodePackageManager(for commands: [String], in projectRoot: URL) -> NodePackageManager {
        let lowered = commands.map { $0.lowercased() }
        if lowered.contains(where: { $0.contains("pnpm") }) {
            return .pnpm
        }
        if lowered.contains(where: { $0.contains("yarn") }) {
            return .yarn
        }
        if lowered.contains(where: { $0.contains("bun") }) {
            return .bun
        }
        if lowered.contains(where: { $0.contains("npm") }) {
            return .npm
        }

        if fileManager.fileExists(atPath: projectRoot.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if fileManager.fileExists(atPath: projectRoot.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        if fileManager.fileExists(atPath: projectRoot.appendingPathComponent("bun.lock").path) ||
            fileManager.fileExists(atPath: projectRoot.appendingPathComponent("bun.lockb").path) {
            return .bun
        }

        return .npm
    }

    nonisolated private static func runShellCommand(path: String, command: String) -> Bool {
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "cd \(escapedPath) && \(command)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func openInEditor(project: ProjectConfig, editor: EditorType) {
        let path = project.expandedPath

        guard fileManager.fileExists(atPath: path) else {
            statusMessage = "\(project.name): path not found"
            return
        }

        if openApplicationWithPath(appName: editor.appName, path: path) {
            statusMessage = "\(project.name): opened in \(editor.displayName)"
        } else {
            statusMessage = "\(project.name): \(editor.displayName) 실행 실패"
        }
    }

    func runBulkCommitAndPushWithClaude(projects: [ProjectConfig]) {
        if isBulkCommitRunning {
            statusMessage = "Bulk commit/push is already running"
            return
        }

        let snapshots = projects.map {
            ClaudeTargetProject(
                name: $0.name,
                path: $0.expandedPath,
                isNextJS: Self.isNextJSProject(path: $0.expandedPath)
            )
        }

        guard !snapshots.isEmpty else {
            statusMessage = "No projects to process"
            return
        }

        isBulkCommitRunning = true
        defer { isBulkCommitRunning = false }

        startClaudeCommitAndPush(
            projects: snapshots,
            prompt: Self.buildClaudeBulkCommitPrompt(projects: snapshots),
            runFilePrefix: "bulk-commit-push-claude",
            marker: "mdc-bulk-commit-push",
            title: "Bulk Commit/Push",
            successMessage: "Opened iTerm and started Claude bulk commit/push",
            failureMessage: "Failed to open iTerm for Claude bulk commit/push"
        )
    }

    func runProjectCommitAndPushWithClaude(project: ProjectConfig) {
        if commitPushProjectsLaunching.contains(project.name) {
            statusMessage = "\(project.name): commit/push launch is already in progress"
            return
        }

        let snapshot = ClaudeTargetProject(
            name: project.name,
            path: project.expandedPath,
            isNextJS: Self.isNextJSProject(path: project.expandedPath)
        )

        commitPushProjectsLaunching.insert(project.name)
        defer { commitPushProjectsLaunching.remove(project.name) }

        startClaudeCommitAndPush(
            projects: [snapshot],
            prompt: Self.buildClaudeSingleCommitPrompt(project: snapshot),
            runFilePrefix: "single-commit-push-claude-\(sanitize(project.name))",
            marker: "mdc-single-commit-push-\(sanitize(project.name))",
            title: "Commit/Push - \(project.name)",
            successMessage: "\(project.name): opened iTerm and started Claude commit/push",
            failureMessage: "\(project.name): failed to open iTerm for Claude commit/push"
        )
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

    nonisolated private static func findClaudeExecutable() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent("claude").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    nonisolated private static func isNextJSProject(path: String) -> Bool {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let nextConfigNames = [
            "next.config.js",
            "next.config.cjs",
            "next.config.mjs",
            "next.config.ts"
        ]

        for configName in nextConfigNames {
            if fileManager.fileExists(atPath: root.appendingPathComponent(configName).path) {
                return true
            }
        }

        let packageURL = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let dependencySections = ["dependencies", "devDependencies", "peerDependencies"]
        for key in dependencySections {
            if let deps = decoded[key] as? [String: Any], deps["next"] != nil {
                return true
            }
        }

        if let scripts = decoded["scripts"] as? [String: Any],
           let buildScript = scripts["build"] as? String,
           buildScript.lowercased().contains("next") {
            return true
        }

        return false
    }

    nonisolated private static func buildClaudeBulkCommitPrompt(projects: [ClaudeTargetProject]) -> String {
        let projectLines = projects
            .map { "- \($0.name): \($0.path)" }
            .joined(separator: "\n")
        let nextProjectLines = projects
            .filter(\.isNextJS)
            .map { "- \($0.name): \($0.path)" }
            .joined(separator: "\n")
        let nonNextProjectLines = projects
            .filter { !$0.isNextJS }
            .map { "- \($0.name): \($0.path)" }
            .joined(separator: "\n")

        return """
        다음 경로들에서 전체 커밋 및 푸시 작업을 수행해줘.

        프로젝트 목록:
        \(projectLines)

        Next.js 프로젝트 (빌드 후 커밋/푸시):
        \(nextProjectLines.isEmpty ? "- 없음" : nextProjectLines)

        기타 프로젝트 (커밋/푸시):
        \(nonNextProjectLines.isEmpty ? "- 없음" : nonNextProjectLines)

        작업 규칙:
        1) 각 경로가 git 저장소인지 확인하고 작업한다.
        2) 변경사항이 없으면 해당 경로는 스킵한다.
        3) Next.js 프로젝트는 사용 중인 패키지 매니저를 감지해서 빌드 명령(예: npm run build / pnpm build / yarn build)을 먼저 실행하고, 빌드 성공 시 커밋 후 푸시한다.
        4) Next.js가 아닌 프로젝트는 빌드 없이 커밋 후 푸시한다.
        5) 커밋 메시지는 변경사항을 요약해서 작성한다.
        6) 푸시는 현재 브랜치 upstream으로 진행한다.
        7) 프로젝트별 결과(성공/실패, 커밋 해시, push 결과, 실패 원인)를 마지막에 요약한다.

        실패한 프로젝트가 있어도 나머지는 계속 진행해줘.
        """
    }

    nonisolated private static func buildClaudeSingleCommitPrompt(project: ClaudeTargetProject) -> String {
        let buildRule: String
        if project.isNextJS {
            buildRule = "이 프로젝트는 Next.js로 분류되므로, 패키지 매니저를 감지해서 빌드 명령(예: npm run build / pnpm build / yarn build)을 먼저 실행하고, 빌드 성공 시 커밋 후 푸시한다."
        } else {
            buildRule = "이 프로젝트는 Next.js가 아니므로 빌드 없이 커밋 후 푸시한다."
        }

        return """
        다음 단일 프로젝트에서 커밋 및 푸시 작업을 수행해줘.

        프로젝트:
        - \(project.name): \(project.path)

        작업 규칙:
        1) 해당 경로가 git 저장소인지 확인하고 작업한다.
        2) 변경사항이 없으면 스킵한다.
        3) \(buildRule)
        4) 커밋 메시지는 변경사항을 요약해서 작성한다.
        5) 푸시는 현재 브랜치 upstream으로 진행한다.
        6) 결과(성공/실패, 커밋 해시, push 결과, 실패 원인)를 마지막에 요약한다.
        """
    }

    private func startClaudeCommitAndPush(
        projects: [ClaudeTargetProject],
        prompt: String,
        runFilePrefix: String,
        marker: String,
        title: String,
        successMessage: String,
        failureMessage: String
    ) {
        guard let claudePath = Self.findClaudeExecutable() else {
            statusMessage = "Claude CLI not found"
            return
        }

        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Unable to prepare logs directory: \(error.localizedDescription)"
            return
        }

        let runID = Int(Date().timeIntervalSince1970)
        let promptURL = logsDirectory.appendingPathComponent("\(runFilePrefix)-\(runID).prompt.txt")
        let streamLogURL = logsDirectory.appendingPathComponent("\(runFilePrefix)-\(runID).stream.log")

        do {
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "Unable to write Claude prompt: \(error.localizedDescription)"
            return
        }

        let command = buildClaudeItermCommand(
            claudePath: claudePath,
            projects: projects,
            promptFilePath: promptURL.path,
            streamLogPath: streamLogURL.path
        )

        if openInIterm(
            path: fileManager.homeDirectoryForCurrentUser.path,
            command: command,
            marker: marker,
            title: title
        ) != nil {
            statusMessage = successMessage
        } else {
            statusMessage = failureMessage
        }
    }

    private func buildClaudeItermCommand(
        claudePath: String,
        projects: [ClaudeTargetProject],
        promptFilePath: String,
        streamLogPath: String
    ) -> String {
        let addDirArgs = projects
            .map { "--add-dir \(shellEscape($0.path))" }
            .joined(separator: " ")

        let escapedClaudePath = shellEscape(claudePath)
        let escapedPromptPath = shellEscape(promptFilePath)
        let escapedStreamLogPath = shellEscape(streamLogPath)
        return """
        set -o pipefail; \
        echo '[multi-dev-ctrl] Starting Claude commit/push...'; \
        \(escapedClaudePath) --print --verbose --output-format stream-json --include-partial-messages --permission-mode bypassPermissions \(addDirArgs) "$(cat \(escapedPromptPath))" \
        | /usr/bin/tee \(escapedStreamLogPath) \
        | /usr/bin/jq -r 'if .type=="assistant" then (.message.content[]? | if .type=="text" then .text elif .type=="tool_use" then "[tool] " + .name + " " + (.input|tostring) else empty end) elif .type=="user" and .tool_use_result? then (if (.tool_use_result.stdout // "") != "" then "[tool-result]\\n" + .tool_use_result.stdout elif (.tool_use_result.stderr // "") != "" then "[tool-stderr]\\n" + .tool_use_result.stderr else empty end) elif .type=="result" then "[done] " + (.subtype // "") + " in " + ((.duration_ms|tostring) // "") + "ms" else empty end'; \
        _mdc_ec=$?; \
        echo ''; \
        echo '[multi-dev-ctrl] Claude session ended (exit:' $_mdc_ec')'; \
        echo '[multi-dev-ctrl] Stream log:' \(escapedStreamLogPath)
        """
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

    func killPort(_ port: Int, projectPath: String? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            // lsof로 PID 찾아서 kill
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "lsof -t -i :\(port) | xargs kill -9 2>/dev/null; exit 0"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}

            if let path = projectPath {
                let lockPath = URL(fileURLWithPath: path)
                    .appendingPathComponent(".next/dev/lock").path
                try? FileManager.default.removeItem(atPath: lockPath)
            }

            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { completion?() }
        }
    }

    func killListeningPorts(projects: [ProjectConfig], completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for project in projects {
            guard let port = port(for: project, in: projects) else {
                continue
            }
            group.enter()
            killPort(port, projectPath: project.expandedPath) {
                group.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            group.wait()
            DispatchQueue.main.async {
                self?.statusMessage = "전체 중지 완료"
                completion?()
            }
        }
    }

    func stop(project: ProjectConfig, allProjects _: [ProjectConfig], silent: Bool = false) {
        let projectName = project.name
        let managedProcesses = processesByProject.removeValue(forKey: projectName) ?? []
        let hadManagedProcess = !managedProcesses.isEmpty

        for entry in managedProcesses {
            if entry.process.isRunning {
                entry.process.terminate()
            }
            entry.logFileHandle?.closeFile()
        }

        let stopCommandResult = runStopCommandIfNeeded(project: project)
        runningProjects.remove(projectName)
        runtimePortsByProject.removeValue(forKey: projectName)

        guard hadManagedProcess || stopCommandResult != .notConfigured else {
            return
        }

        if !silent, stopCommandResult == .succeeded {
            statusMessage = "\(projectName): stopped (종료 스크립트 실행)"
        } else if !silent, stopCommandResult == .failed {
            statusMessage = "\(projectName): stopped (종료 스크립트 실패)"
        } else if !silent {
            statusMessage = "\(projectName): stopped"
        }
    }

    private func runStopCommandIfNeeded(project: ProjectConfig) -> StopCommandResult {
        guard var command = project.stopCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .notConfigured
        }

        let runtimePort = runtimePortsByProject[project.name] ?? preferredPortForProject(project)
        command = replacePortPlaceholder(in: command, runtimePort: runtimePort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "cd \(shellEscape(project.expandedPath)) && \(command)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .succeeded : .failed
        } catch {
            statusMessage = "\(project.name): 종료 스크립트 실행 실패 (\(error.localizedDescription))"
            return .failed
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
            runtimePortsByProject.removeValue(forKey: projectName)
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

    private func openInIterm(path: String, command: String?, marker: String, title: String, mode: ItermMode = .window) -> Int? {
        let joinedCommand = buildItermCommand(path: path, command: command, title: title)

        let appleScriptCommand = escapeForAppleScript(joinedCommand)
        let escapedMarker = escapeForAppleScript(marker)

        let script: String
        if mode == .tab {
            script = """
            tell application "iTerm"
                activate
                if (count of windows) = 0 then
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        set name to "\(escapedMarker)"
                        write text "\(appleScriptCommand)"
                    end tell
                    return id of newWindow
                else
                    tell current window
                        set newTab to (create tab with default profile)
                        tell current session of newTab
                            set name to "\(escapedMarker)"
                            write text "\(appleScriptCommand)"
                        end tell
                        return id
                    end tell
                end if
            end tell
            """
        } else {
            script = """
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
        }

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

    private func openWithCodeCLI(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["code", path]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
    @ObservedObject var portStore: PortStatusStore
    var addProjectController: AddProjectWindowController
    var archivedProjectsController: ArchivedProjectsWindowController
    var logViewerController: LogViewerWindowController

    private var groupedProjects: [(group: String, projects: [ProjectConfig])] {
        let projects = configStore.enabledProjects
        var groupOrder: [String] = []
        var groupMap: [String: [ProjectConfig]] = [:]

        for project in projects {
            let group = configStore.displayGroupName(for: project)
            if groupMap[group] == nil {
                groupOrder.append(group)
            }
            groupMap[group, default: []].append(project)
        }

        return groupOrder.map { (group: $0, projects: groupMap[$0]!) }
    }

    var body: some View {
        let enabledProjects = configStore.enabledProjects
        let allProjectsRunning = !enabledProjects.isEmpty && enabledProjects.allSatisfy { isProjectRunning($0) }

        VStack(alignment: .leading, spacing: 0) {
            if configStore.projects.isEmpty {
                Text("프로젝트 없음")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            } else if groupedProjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("활성 프로젝트 없음")
                        .font(.system(size: 13, weight: .medium))
                    Text("비활성 프로젝트 관리에서 복구할 수 있습니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            } else {
                ForEach(Array(groupedProjects.enumerated()), id: \.offset) { index, section in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    groupHeaderRow(group: section.group, projects: section.projects)
                    Divider()

                    ForEach(section.projects) { project in
                        projectRow(project)
                        Divider()
                    }
                }
            }

            Divider().padding(.vertical, 8)

            utilityButton(
                title: allProjectsRunning ? "전체 종료" : "전체 실행",
                systemName: allProjectsRunning ? "stop.circle" : "play.circle",
                disabled: enabledProjects.isEmpty
            ) {
                if allProjectsRunning {
                    stopProjects(configStore.projects, silent: true)
                } else {
                    runProjects(enabledProjects.filter { !isProjectRunning($0) })
                }
            }

            utilityButton(
                title: runner.isBulkCommitRunning ? "전체 커밋 및 푸시 실행 중..." : "전체 커밋 및 푸시",
                systemName: "arrow.up.circle",
                disabled: enabledProjects.isEmpty || runner.isBulkCommitRunning
            ) {
                runner.runBulkCommitAndPushWithClaude(projects: enabledProjects)
            }

            utilityButton(title: "프로젝트 추가", systemName: "plus") {
                addProjectController.showAddProject(configStore: configStore)
            }

            utilityButton(title: "비활성 프로젝트 관리", systemName: "archivebox") {
                archivedProjectsController.show(configStore: configStore)
            }

            if !configStore.projects.isEmpty {
                utilityButton(title: "프로젝트 설정 제거", systemName: "trash") {
                    configStore.promptAndRemoveProject()
                }
            }

            utilityButton(title: "설정 새로고침", systemName: "arrow.clockwise") {
                configStore.reload()
                gitStore.refresh(projects: configStore.projects)
            }

            utilityButton(title: "설정 폴더 열기", systemName: "folder") {
                configStore.openConfigFolder()
            }

            utilityMenu(title: "에디터: \(configStore.editor.displayName)", systemName: "chevron.left.forwardslash.chevron.right") {
                ForEach(EditorType.allCases, id: \.self) { editor in
                    Button("\(configStore.editor == editor ? "✓ " : "   ")\(editor.displayName)") {
                        configStore.setEditor(editor)
                    }
                }
            }

            utilityMenu(title: "iTerm 모드: \(configStore.itermMode == .tab ? "탭" : "윈도우")", systemName: "rectangle.split.2x1") {
                Button("\(configStore.itermMode == .tab ? "✓ " : "   ")탭 모드") {
                    configStore.setItermMode(.tab)
                }
                Button("\(configStore.itermMode == .window ? "✓ " : "   ")윈도우 모드") {
                    configStore.setItermMode(.window)
                }
            }

            if let message = runner.statusMessage ?? configStore.statusMessage {
                Divider().padding(.vertical, 8)
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }

            Divider().padding(.top, 8).padding(.bottom, 6)

            utilityButton(title: "종료", systemName: "xmark.circle") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func isProjectRunning(_ project: ProjectConfig) -> Bool {
        if runner.runningProjects.contains(project.name) {
            return true
        }

        guard let port = runner.port(for: project, in: configStore.projects) else {
            return false
        }

        return portStore.isPortListening(port)
    }

    private func runProject(_ project: ProjectConfig) {
        guard project.isEnabled || isProjectRunning(project) else {
            runner.run(project, allProjects: configStore.projects, itermMode: configStore.itermMode)
            return
        }

        guard !isProjectRunning(project) else { return }
        runner.run(project, allProjects: configStore.projects, itermMode: configStore.itermMode)
    }

    private func runProjects(_ projects: [ProjectConfig]) {
        for project in projects where project.isEnabled {
            runProject(project)
        }
    }

    private func stopProjects(_ projects: [ProjectConfig], silent: Bool, completion: (() -> Void)? = nil) {
        let activeProjects = projects.filter { isProjectRunning($0) }
        guard !activeProjects.isEmpty else {
            completion?()
            return
        }

        let stopGroup = DispatchGroup()

        for project in activeProjects {
            let portToKill = runner.runtimePort(for: project) ?? runner.port(for: project, in: configStore.projects)
            runner.stop(project: project, allProjects: configStore.projects, silent: silent)
            if let portToKill {
                stopGroup.enter()
                runner.killPort(portToKill, projectPath: project.expandedPath) {
                    stopGroup.leave()
                }
            }
        }

        stopGroup.notify(queue: .main) {
            portStore.forceRefresh()
            completion?()
        }
    }

    private func archiveGroup(group: String, projects: [ProjectConfig]) {
        stopProjects(projects, silent: true) {
            configStore.setGroupEnabled(named: group, isEnabled: false)
        }
    }

    private func restartProject(_ project: ProjectConfig) {
        stopProjects([project], silent: true) {
            runProject(project)
        }
    }

    private func restartProjects(_ projects: [ProjectConfig]) {
        let runningOnes = projects.filter { isProjectRunning($0) }
        guard !runningOnes.isEmpty else { return }
        stopProjects(runningOnes, silent: true) {
            runProjects(runningOnes)
        }
    }

    @ViewBuilder
    private func utilityButton(
        title: String,
        systemName: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            utilityRowLabel(title: title, systemName: systemName, showsChevron: false)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func utilityMenu<Content: View>(
        title: String,
        systemName: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            utilityRowLabel(title: title, systemName: systemName, showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func utilityRowLabel(
        title: String,
        systemName: String,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func iconActionButton(
        systemName: String,
        helpText: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(disabled ? Color.secondary : tint)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(disabled ? Color(nsColor: .controlBackgroundColor).opacity(0.4) : tint.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(disabled ? Color.clear : tint.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }

    @ViewBuilder
    private func iconMenuButton<Content: View>(
        systemName: String,
        helpText: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(tint)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }

    @ViewBuilder
    private func groupEditButton(group: String, projects: [ProjectConfig]) -> some View {
        iconMenuButton(systemName: "pencil", helpText: "\(group) 그룹 수정", tint: .secondary) {
            ForEach(projects) { project in
                Button(project.name) {
                    addProjectController.showEditProject(project: project, configStore: configStore)
                }
            }
        }
    }

    @ViewBuilder
    private func runStopButton(
        isRunning: Bool,
        runDisabled: Bool = false,
        runLabel: String,
        stopLabel: String,
        runAction: @escaping () -> Void,
        stopAction: @escaping () -> Void
    ) -> some View {
        if isRunning {
            iconActionButton(systemName: "stop.fill", helpText: stopLabel, tint: .red, action: stopAction)
        } else {
            iconActionButton(systemName: "play.fill", helpText: runLabel, tint: .blue, disabled: runDisabled, action: runAction)
        }
    }

    @ViewBuilder
    private func groupHeaderRow(group: String, projects: [ProjectConfig]) -> some View {
        let hasRunning = projects.contains { isProjectRunning($0) }
        let hasStopped = projects.contains { !isProjectRunning($0) }
        let showStop = hasRunning

        HStack(spacing: 8) {
            Text(group)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer(minLength: 8)
            if hasRunning {
                iconActionButton(systemName: "arrow.clockwise", helpText: "\(group) 그룹 재실행", tint: .orange) {
                    restartProjects(projects)
                }
            }
            runStopButton(
                isRunning: showStop,
                runLabel: "\(group) 그룹 실행",
                stopLabel: "\(group) 그룹 중지",
                runAction: { runProjects(projects.filter { !isProjectRunning($0) }) },
                stopAction: { stopProjects(projects, silent: true) }
            )
            iconActionButton(systemName: "archivebox", helpText: "\(group) 그룹 비활성화", tint: .orange) {
                archiveGroup(group: group, projects: projects)
            }
            groupEditButton(group: group, projects: projects)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity((hasRunning || hasStopped) ? 1 : 0.8)
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectConfig) -> some View {
        let port = runner.port(for: project, in: configStore.projects)
        let isRunning = isProjectRunning(project)
        let needsCommit = gitStore.state(for: project) == .needsCommit

        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.7))
                .frame(width: 8, height: 8)

            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isRunning ? Color.primary : Color.secondary)

            if let port {
                Text(":\(port)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if needsCommit {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                iconActionButton(systemName: "doc.text.magnifyingglass", helpText: "\(project.name) 로그 보기", tint: .secondary) {
                    logViewerController.showLog(for: project.name)
                }
                if isRunning {
                    iconActionButton(systemName: "arrow.clockwise", helpText: "\(project.name) 재실행", tint: .orange) {
                        restartProject(project)
                    }
                }
                runStopButton(
                    isRunning: isRunning,
                    runLabel: "\(project.name) 실행",
                    stopLabel: "\(project.name) 중지",
                    runAction: { runProject(project) },
                    stopAction: { stopProjects([project], silent: false) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isRunning
                        ? Color(nsColor: .systemGreen).opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.3)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isRunning
                        ? Color(nsColor: .systemGreen).opacity(0.33)
                        : Color(nsColor: .separatorColor).opacity(0.2),
                    lineWidth: 1
                )
        )
    }
}

struct MultiDevCtrlApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var runner = ProjectRunner()
    @StateObject private var gitStore = GitStatusStore()
    @StateObject private var portStore = PortStatusStore()
    @State private var didSetup = false
    private let addProjectController = AddProjectWindowController()
    private let archivedProjectsController = ArchivedProjectsWindowController()
    private let logViewerController = LogViewerWindowController()

    var body: some Scene {
        MenuBarExtra("Dev Ctrl", systemImage: "terminal") {
            MenuContentView(
                configStore: configStore,
                runner: runner,
                gitStore: gitStore,
                portStore: portStore,
                addProjectController: addProjectController,
                archivedProjectsController: archivedProjectsController,
                logViewerController: logViewerController
            )
                .frame(width: 520)
                .onAppear {
                    guard !didSetup else { return }
                    didSetup = true
                    configStore.reload()
                    gitStore.refresh(projects: configStore.projects)
                    portStore.startMonitoring()
                }
                .onChange(of: configStore.projects) { _, projects in
                    gitStore.refresh(projects: projects)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

MultiDevCtrlApp.main()

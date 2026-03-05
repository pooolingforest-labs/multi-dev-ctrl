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

struct AppConfig: Codable {
    let projects: [ProjectConfig]
    var itermMode: ItermMode?
    var editor: EditorType?
}

struct ProjectConfig: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let actions: [ProjectAction]
    let group: String?
    var id: String { name }

    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    enum CodingKeys: String, CodingKey {
        case name, path, actions, group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        actions = try container.decode([ProjectAction].self, forKey: .actions)
        group = try container.decodeIfPresent(String.self, forKey: .group)
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
    @Published private(set) var statusMessage: String?
    @Published var itermMode: ItermMode = .window
    @Published var editor: EditorType = .cursor

    private let fileManager = FileManager.default
    private var currentConfigURL: URL?

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

@MainActor
final class ProjectRunner: ObservableObject {
    @Published private(set) var runningProjects: Set<String> = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBulkCommitRunning = false
    @Published private(set) var commitPushProjectsLaunching: Set<String> = []

    private let fileManager = FileManager.default
    private var processesByProject: [String: [ManagedProcess]] = [:]
    private var terminalWindowIDsByProject: [String: Int] = [:]
    private func portForProject(_ project: ProjectConfig, in projects: [ProjectConfig]) -> Int {
        let index = projects.firstIndex(where: { $0.name == project.name }) ?? 0
        return 3000 + index
    }

    func port(for project: ProjectConfig, in projects: [ProjectConfig]) -> Int {
        portForProject(project, in: projects)
    }

    private var logsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    func run(_ project: ProjectConfig, allProjects: [ProjectConfig], itermMode: ItermMode = .window) {
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
        let port = portForProject(project, in: allProjects)
        let portStr = String(port)

        for action in project.actions {
            switch action.type {
            case .runCommand:
                guard var command = action.command, !command.isEmpty else {
                    statusMessage = "\(project.name): runCommand requires a command"
                    continue
                }
                command = command.replacingOccurrences(of: "$PORT", with: portStr)

                do {
                    try launchBackgroundCommand(projectName: project.name, path: project.expandedPath, command: command)
                    startedBackgroundProcess = true
                } catch {
                    statusMessage = "\(project.name): command failed to start (\(error.localizedDescription))"
                }

            case .openIterm:
                var command = action.command
                command = command?.replacingOccurrences(of: "$PORT", with: portStr)
                if let windowID = openInIterm(path: project.expandedPath, command: command, marker: projectMarker, title: projectTitle, mode: itermMode) {
                    if windowID > 0 {
                        terminalWindowIDsByProject[project.name] = windowID
                    }
                    statusMessage = "\(project.name): opened iTerm"
                } else {
                    statusMessage = "\(project.name): failed to open iTerm"
                }

            case .openItermSplit:
                let commands = normalizedCommands(action.commands?.map { $0.replacingOccurrences(of: "$PORT", with: portStr) })
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
            let port = portForProject(project, in: projects)
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

    private var groupedProjects: [(group: String, projects: [ProjectConfig])] {
        let projects = configStore.projects
        var groupOrder: [String] = []
        var groupMap: [String: [ProjectConfig]] = [:]

        for project in projects {
            let group = project.group ?? "기타"
            if groupMap[group] == nil {
                groupOrder.append(group)
            }
            groupMap[group, default: []].append(project)
        }

        return groupOrder.map { (group: $0, projects: groupMap[$0]!) }
    }

    var body: some View {
        if configStore.projects.isEmpty {
            Text("프로젝트 없음")
        } else {
            ForEach(Array(groupedProjects.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                Text(section.group)
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(section.projects) { project in
                    projectRow(project)
                }
            }
        }

        Divider()

        Button("▶  전체 실행") {
            for project in configStore.projects {
                let port = runner.port(for: project, in: configStore.projects)
                let alreadyRunning = runner.runningProjects.contains(project.name) || portStore.isPortListening(port)
                if !alreadyRunning {
                    runner.run(project, allProjects: configStore.projects, itermMode: configStore.itermMode)
                }
            }
        }
        .disabled(configStore.projects.isEmpty)

        Button("■  전체 중지") {
            for project in configStore.projects {
                runner.stop(projectName: project.name, silent: true)
            }
            runner.killListeningPorts(projects: configStore.projects) {
                portStore.forceRefresh()
            }
        }
        .disabled(configStore.projects.isEmpty)

        Button(runner.isBulkCommitRunning ? "전체 커밋 및 푸시 실행 중..." : "전체 커밋 및 푸시") {
            runner.runBulkCommitAndPushWithClaude(projects: configStore.projects)
        }
        .disabled(configStore.projects.isEmpty || runner.isBulkCommitRunning)

        Divider()

        Button("설정 새로고침") {
            configStore.reload()
            gitStore.refresh(projects: configStore.projects)
        }

        Button("설정 폴더 열기") {
            configStore.openConfigFolder()
        }

        Menu("에디터: \(configStore.editor.displayName)") {
            ForEach(EditorType.allCases, id: \.self) { editor in
                Button("\(configStore.editor == editor ? "✓ " : "   ")\(editor.displayName)") {
                    configStore.setEditor(editor)
                }
            }
        }

        Menu("iTerm 모드: \(configStore.itermMode == .tab ? "탭" : "윈도우")") {
            Button("\(configStore.itermMode == .tab ? "✓ " : "   ")탭 모드") {
                configStore.setItermMode(.tab)
            }
            Button("\(configStore.itermMode == .window ? "✓ " : "   ")윈도우 모드") {
                configStore.setItermMode(.window)
            }
        }

        if let message = runner.statusMessage ?? configStore.statusMessage {
            Divider()
            Text(message)
        }

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func projectLabel(_ project: ProjectConfig) -> String {
        let port = runner.port(for: project, in: configStore.projects)
        let isRunning = runner.runningProjects.contains(project.name) || portStore.isPortListening(port)
        let state = gitStore.state(for: project)
        let dirty = state == .needsCommit ? " ✗" : ""

        if isRunning {
            return "🟢 \(project.name) :\(String(port))\(dirty)"
        } else {
            return "○  \(project.name)\(dirty)"
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectConfig) -> some View {
        let port = runner.port(for: project, in: configStore.projects)
        let isRunning = runner.runningProjects.contains(project.name) || portStore.isPortListening(port)

        Menu(projectLabel(project)) {
            Button("▶  실행") {
                runner.run(project, allProjects: configStore.projects, itermMode: configStore.itermMode)
            }

            Button("↗  코드 (\(configStore.editor.displayName))") {
                runner.openInEditor(project: project, editor: configStore.editor)
            }

            Button(runner.commitPushProjectsLaunching.contains(project.name) ? "⏳ 실행 중..." : "⬆  커밋 & 푸시") {
                runner.runProjectCommitAndPushWithClaude(project: project)
            }
            .disabled(runner.commitPushProjectsLaunching.contains(project.name))

            if isRunning {
                Divider()
                Button("■  중지") {
                    runner.stop(projectName: project.name)
                    runner.killPort(port, projectPath: project.expandedPath) {
                        portStore.forceRefresh()
                    }
                }
            }
        }
    }
}

@main
struct MultiDevCtrlApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var runner = ProjectRunner()
    @StateObject private var gitStore = GitStatusStore()
    @StateObject private var portStore = PortStatusStore()
    @State private var didSetup = false

    var body: some Scene {
        MenuBarExtra("Dev Ctrl", systemImage: "terminal") {
            MenuContentView(configStore: configStore, runner: runner, gitStore: gitStore, portStore: portStore)
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
        .menuBarExtraStyle(.menu)
    }
}

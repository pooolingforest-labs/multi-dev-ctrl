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

    func openInVSCode(project: ProjectConfig) {
        let path = project.expandedPath

        guard fileManager.fileExists(atPath: path) else {
            statusMessage = "\(project.name): path not found"
            return
        }

        if openApplicationWithPath(appName: "Visual Studio Code", path: path) ||
            openApplicationWithPath(appName: "Visual Studio Code - Insiders", path: path) ||
            openWithCodeCLI(path: path) {
            statusMessage = "\(project.name): opened in VS Code"
        } else {
            statusMessage = "\(project.name): failed to open VS Code"
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

    var body: some View {
        if configStore.projects.isEmpty {
            Text("No projects")
        } else {
            ForEach(configStore.projects) { project in
                HStack(spacing: 10) {
                    Button {
                        runner.run(project)
                    } label: {
                        let state = gitStore.state(for: project)
                        Label("\(project.name) \(state.marker)", systemImage: runner.runningProjects.contains(project.name) ? "bolt.fill" : "play")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help(gitStore.state(for: project).description)

                    Button("Code") {
                        runner.openInVSCode(project: project)
                    }

                    Button(runner.commitPushProjectsLaunching.contains(project.name) ? "실행 중..." : "커밋&푸시") {
                        runner.runProjectCommitAndPushWithClaude(project: project)
                    }
                    .disabled(runner.commitPushProjectsLaunching.contains(project.name))
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
            gitStore.refresh(projects: configStore.projects)
        }

        Button(runner.isBulkCommitRunning ? "전체 커밋 및 푸시 실행 중..." : "전체 커밋 및 푸시") {
            runner.runBulkCommitAndPushWithClaude(projects: configStore.projects)
        }
        .disabled(configStore.projects.isEmpty || runner.isBulkCommitRunning)

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
    @State private var isMenuBarInserted = true

    var body: some Scene {
        MenuBarExtra("Dev Ctrl", systemImage: "terminal", isInserted: $isMenuBarInserted) {
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

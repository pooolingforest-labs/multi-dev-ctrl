import Foundation
import SwiftUI

enum DevStackPreset: String, CaseIterable, Identifiable {
    case nextjs = "Next.js"
    case reactVite = "React (Vite)"
    case springBootGradle = "Spring Boot (Gradle)"
    case springBootMaven = "Spring Boot (Maven)"
    case django = "Django"
    case flask = "Flask"
    case goRun = "Go"
    case custom = "직접 입력"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var defaultCommand: String {
        switch self {
        case .nextjs: return "npm run dev"
        case .reactVite: return "npm run dev"
        case .springBootGradle: return "./gradlew bootRun"
        case .springBootMaven: return "./mvnw spring-boot:run"
        case .django: return "python manage.py runserver"
        case .flask: return "flask run"
        case .goRun: return "go run ."
        case .custom: return ""
        }
    }
}

enum CommandSourceType: String, CaseIterable {
    case stack = "개발 스택"
    case script = "스크립트 파일"
}

@MainActor
final class AddProjectState: ObservableObject {
    @Published var projectName = ""
    @Published var projectPath: URL?
    @Published var projectType: ProjectType = .client
    @Published var fixedPort = ""
    @Published var selectedGroup = ""
    @Published var useNewGroup = false
    @Published var newGroupName = ""
    @Published var commandSourceType: CommandSourceType = .stack
    @Published var selectedStack: DevStackPreset = .nextjs
    @Published var customCommand = ""
    @Published var scriptFileURL: URL?
    @Published var stopScriptFileURL: URL?
    @Published var isEnabled = true
    @Published var springProfile = ""

    @Published var isEditMode = false
    var originalName: String?

    func initializeGroupSelection(existingGroups: [String]) {
        guard !useNewGroup else { return }
        if selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedGroup = existingGroups.first ?? ""
        }
    }

    func restoreExistingGroupSelectionIfNeeded(existingGroups: [String]) {
        guard !useNewGroup else { return }
        let trimmed = selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !existingGroups.contains(trimmed) {
            selectedGroup = existingGroups.first ?? ""
        } else {
            selectedGroup = trimmed
        }
    }

    func loadFrom(project: ProjectConfig) {
        isEditMode = true
        originalName = project.name
        projectName = project.name
        projectPath = URL(fileURLWithPath: project.expandedPath)
        projectType = project.projectType
        fixedPort = project.port.map(String.init) ?? ""
        isEnabled = project.isEnabled

        if let group = project.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            selectedGroup = group
        }

        if let firstAction = project.actions.first, let command = firstAction.command {
            if let preset = DevStackPreset.allCases.first(where: { $0 != .custom && $0.defaultCommand == command }) {
                commandSourceType = .stack
                selectedStack = preset
            } else {
                commandSourceType = .stack
                selectedStack = .custom
                customCommand = command
            }
        }

        if let stopCommand = project.stopCommand {
            stopScriptFileURL = URL(fileURLWithPath: stopCommand)
        }

        if let profile = project.springProfile {
            springProfile = profile
        }
    }

    var resolvedGroup: String? {
        if useNewGroup {
            let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmed = selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isSpringBoot: Bool {
        commandSourceType == .stack && (selectedStack == .springBootGradle || selectedStack == .springBootMaven)
    }

    var isValid: Bool {
        guard let path = projectPath else { return false }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        if projectType == .server, normalizedFixedPort == nil {
            return false
        }

        switch commandSourceType {
        case .stack:
            if selectedStack == .custom {
                return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .script:
            guard let scriptURL = scriptFileURL else { return false }
            guard FileManager.default.fileExists(atPath: scriptURL.path) else { return false }

            if let stopScriptFileURL {
                return FileManager.default.fileExists(atPath: stopScriptFileURL.path)
            }
            return true
        }
    }

    private var normalizedFixedPort: Int? {
        let trimmed = fixedPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let port = Int(trimmed), (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    func buildProjectConfig() -> [String: Any] {
        var dict: [String: Any] = [
            "name": projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            "path": projectPath?.path ?? "",
            "projectType": projectType.rawValue,
            "isEnabled": isEnabled
        ]

        if let group = resolvedGroup {
            dict["group"] = group
        }

        let command: String
        switch commandSourceType {
        case .stack:
            command = selectedStack == .custom ? customCommand : selectedStack.defaultCommand
        case .script:
            command = scriptFileURL?.path ?? ""
        }

        let action: [String: Any] = [
            "type": "runCommand",
            "command": command
        ]
        dict["actions"] = [action]

        if projectType == .server, let fixedPort = normalizedFixedPort {
            dict["port"] = fixedPort
        }

        if commandSourceType == .script, let stopScriptFileURL {
            dict["stopCommand"] = stopScriptFileURL.path
        }

        let trimmedProfile = springProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSpringBoot && !trimmedProfile.isEmpty {
            dict["springProfile"] = trimmedProfile
        }

        return dict
    }
}

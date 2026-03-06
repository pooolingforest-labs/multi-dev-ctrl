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
    @Published var selectedGroup = ""
    @Published var useNewGroup = false
    @Published var newGroupName = ""
    @Published var commandSourceType: CommandSourceType = .stack
    @Published var selectedStack: DevStackPreset = .nextjs
    @Published var customCommand = ""
    @Published var scriptFileURL: URL?
    @Published var stopScriptFileURL: URL?
    @Published var isEnabled = true

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
    }

    var resolvedGroup: String? {
        if useNewGroup {
            let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmed = selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isValid: Bool {
        guard let path = projectPath else { return false }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

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

    func buildProjectConfig() -> [String: Any] {
        var dict: [String: Any] = [
            "name": projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            "path": projectPath?.path ?? "",
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

        if commandSourceType == .script, let stopScriptFileURL {
            dict["stopCommand"] = stopScriptFileURL.path
        }

        return dict
    }
}

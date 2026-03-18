import AppKit
import Foundation

extension ConfigStore {
    var enabledProjects: [ProjectConfig] {
        projects.filter { $0.isEnabled }
    }

    var archivedProjects: [ProjectConfig] {
        projects.filter { !$0.isEnabled }
    }

    var existingGroups: [String] {
        let groups = projects.compactMap {
            $0.group?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        return Array(Set(groups)).sorted()
    }

    func displayGroupName(for project: ProjectConfig) -> String {
        normalizedGroupName(project.group)
    }

    private func normalizedGroupName(_ rawGroup: String?) -> String {
        let trimmedGroup = rawGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedGroup?.isEmpty == false) ? trimmedGroup! : "기타"
    }

    private func normalizedGroupName(from projectDict: [String: Any]) -> String {
        normalizedGroupName(projectDict["group"] as? String)
    }

    private func normalizedProjectDict(_ projectDict: [String: Any]) -> [String: Any] {
        var normalized = projectDict
        let trimmedGroup = (projectDict["group"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedGroup, !trimmedGroup.isEmpty {
            normalized["group"] = trimmedGroup
        } else {
            normalized.removeValue(forKey: "group")
        }

        let rawProjectType = (projectDict["projectType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let projectType = ProjectType(rawValue: rawProjectType ?? "") ?? .client
        normalized["projectType"] = projectType.rawValue

        if let port = projectDict["port"] as? Int,
           (1...65535).contains(port) {
            normalized["port"] = port
        } else {
            normalized.removeValue(forKey: "port")
        }

        let trimmedProfile = (projectDict["springProfile"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedProfile, !trimmedProfile.isEmpty {
            normalized["springProfile"] = trimmedProfile
        } else {
            normalized.removeValue(forKey: "springProfile")
        }

        return normalized
    }

    func createConfigIfNeeded() {
        let configURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".multi-dev-ctrl/projects.json")
        let dirURL = configURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: configURL.path) {
            do {
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
                let emptyConfig: [String: Any] = ["projects": []]
                let data = try JSONSerialization.data(withJSONObject: emptyConfig, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: configURL)
                currentConfigURL = configURL
            } catch {
                statusMessage = "설정 파일 생성 실패: \(error.localizedDescription)"
            }
        }
    }

    func addProject(_ projectDict: [String: Any]) {
        if currentConfigURL == nil {
            createConfigIfNeeded()
        }
        guard let configURL = currentConfigURL else { return }
        let normalizedProject = normalizedProjectDict(projectDict)

        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var projectsArray = json["projects"] as? [[String: Any]] ?? []

            let newName = normalizedProject["name"] as? String ?? ""
            if projectsArray.contains(where: { ($0["name"] as? String) == newName }) {
                statusMessage = "이름이 중복됩니다: \(newName)"
                return
            }

            projectsArray.append(normalizedProject)
            json["projects"] = projectsArray
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            reload()
            statusMessage = "프로젝트 추가됨: \(newName)"
        } catch {
            statusMessage = "프로젝트 추가 실패: \(error.localizedDescription)"
        }
    }

    func removeProject(named name: String) {
        guard let configURL = currentConfigURL else { return }

        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var projectsArray = json["projects"] as? [[String: Any]] ?? []
            projectsArray.removeAll { ($0["name"] as? String) == name }
            json["projects"] = projectsArray
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            reload()
            statusMessage = "프로젝트 설정 제거됨: \(name)"
        } catch {
            statusMessage = "프로젝트 설정 제거 실패: \(error.localizedDescription)"
        }
    }

    func promptAndRemoveProject() {
        let sortedProjects = projects
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard !sortedProjects.isEmpty else {
            statusMessage = "제거할 프로젝트가 없습니다"
            return
        }

        if sortedProjects.count == 1, let onlyProject = sortedProjects.first {
            confirmAndRemoveProject(named: onlyProject)
            return
        }

        let alert = NSAlert()
        alert.messageText = "프로젝트 설정 제거"
        alert.informativeText = "제거할 프로젝트를 선택하세요.\n(프로젝트 파일은 삭제되지 않습니다)"
        alert.alertStyle = .warning

        let projectSelector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        sortedProjects.forEach { projectSelector.addItem(withTitle: $0) }
        alert.accessoryView = projectSelector

        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")

        guard alert.runModal() == .alertFirstButtonReturn,
              let selectedName = projectSelector.selectedItem?.title else {
            return
        }

        removeProject(named: selectedName)
    }

    func updateProject(named name: String, with projectDict: [String: Any]) {
        guard let configURL = currentConfigURL else { return }
        let normalizedProject = normalizedProjectDict(projectDict)

        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var projectsArray = json["projects"] as? [[String: Any]] ?? []

            guard let index = projectsArray.firstIndex(where: { ($0["name"] as? String) == name }) else {
                statusMessage = "프로젝트를 찾을 수 없습니다: \(name)"
                return
            }

            projectsArray[index] = normalizedProject
            json["projects"] = projectsArray
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            reload()
            statusMessage = "프로젝트 수정됨: \(name)"
        } catch {
            statusMessage = "프로젝트 수정 실패: \(error.localizedDescription)"
        }
    }

    func setProjectEnabled(named name: String, isEnabled: Bool) {
        guard let configURL = currentConfigURL else { return }

        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var projectsArray = json["projects"] as? [[String: Any]] ?? []

            guard let index = projectsArray.firstIndex(where: { ($0["name"] as? String) == name }) else {
                statusMessage = "프로젝트를 찾을 수 없습니다: \(name)"
                return
            }

            projectsArray[index]["isEnabled"] = isEnabled
            json["projects"] = projectsArray
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            reload()
            statusMessage = isEnabled ? "프로젝트 활성화됨: \(name)" : "프로젝트 비활성화됨: \(name)"
        } catch {
            statusMessage = "프로젝트 상태 변경 실패: \(error.localizedDescription)"
        }
    }

    func setGroupEnabled(named group: String, isEnabled: Bool) {
        guard let configURL = currentConfigURL else { return }

        do {
            let data = try Data(contentsOf: configURL)
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var projectsArray = json["projects"] as? [[String: Any]] ?? []
            var affectedCount = 0

            for index in projectsArray.indices where normalizedGroupName(from: projectsArray[index]) == group {
                projectsArray[index]["isEnabled"] = isEnabled
                affectedCount += 1
            }

            guard affectedCount > 0 else {
                statusMessage = "그룹을 찾을 수 없습니다: \(group)"
                return
            }

            json["projects"] = projectsArray
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL)
            reload()
            let stateText = isEnabled ? "활성화" : "비활성화"
            statusMessage = "\(group) 그룹 \(stateText)됨: \(affectedCount)개 프로젝트"
        } catch {
            statusMessage = "그룹 상태 변경 실패: \(error.localizedDescription)"
        }
    }

    func confirmAndRemoveProject(named name: String) {
        let alert = NSAlert()
        alert.messageText = "프로젝트 설정 제거"
        alert.informativeText = "'\(name)' 프로젝트 설정을 목록에서 제거하시겠습니까?\n(프로젝트 파일은 삭제되지 않습니다)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")

        if alert.runModal() == .alertFirstButtonReturn {
            removeProject(named: name)
        }
    }
}

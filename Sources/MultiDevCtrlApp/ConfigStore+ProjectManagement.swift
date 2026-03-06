import AppKit
import Foundation

extension ConfigStore {
    var existingGroups: [String] {
        let groups = projects.compactMap {
            $0.group?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        return Array(Set(groups)).sorted()
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

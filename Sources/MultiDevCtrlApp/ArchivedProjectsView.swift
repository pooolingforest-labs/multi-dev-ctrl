import SwiftUI

struct ArchivedProjectsView: View {
    @ObservedObject var configStore: ConfigStore
    let onClose: () -> Void

    private var groupedArchivedProjects: [(group: String, projects: [ProjectConfig])] {
        let archivedProjects = configStore.archivedProjects
        var groupOrder: [String] = []
        var groupMap: [String: [ProjectConfig]] = [:]

        for project in archivedProjects {
            let group = configStore.displayGroupName(for: project)
            if groupMap[group] == nil {
                groupOrder.append(group)
            }
            groupMap[group, default: []].append(project)
        }

        return groupOrder.map { (group: $0, projects: groupMap[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if groupedArchivedProjects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("비활성 프로젝트 없음")
                        .font(.system(size: 15, weight: .semibold))
                    Text("메인 화면에서 그룹을 비활성화하면 이곳에서 복구할 수 있습니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(groupedArchivedProjects, id: \.group) { section in
                            archivedGroupCard(group: section.group, projects: section.projects)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 460, maxWidth: 460, minHeight: 380, maxHeight: 560)
    }

    @ViewBuilder
    private func archivedGroupCard(group: String, projects: [ProjectConfig]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(group)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(projects.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                Spacer()
                Button("그룹 복구") {
                    configStore.setGroupEnabled(named: group, isEnabled: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                HStack(spacing: 10) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button("복구") {
                        configStore.setProjectEnabled(named: project.name, isEnabled: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if index < projects.count - 1 {
                    Divider()
                        .padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

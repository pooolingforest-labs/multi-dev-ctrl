import AppKit
import SwiftUI

struct AddProjectView: View {
    @ObservedObject var state: AddProjectState
    let existingGroups: [String]
    let onAdd: ([String: Any]) -> Void
    let onCancel: () -> Void
    @State private var isGroupDropdownOpen = false
    @State private var groupDropdownAnchor: CGRect = .zero
    @State private var isStackDropdownOpen = false
    @State private var stackDropdownAnchor: CGRect = .zero
    @State private var rootContainerSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("프로젝트 경로") {
                    HStack {
                        Text(state.projectPath?.path ?? "선택되지 않음")
                            .foregroundColor(state.projectPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("선택...") {
                            chooseDirectory()
                        }
                    }
                }

                Section("프로젝트 이름") {
                    TextField("프로젝트 이름", text: $state.projectName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(state.isEditMode)
                }

                Section("프로젝트 유형") {
                    Picker("", selection: $state.projectType) {
                        ForEach(ProjectType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if state.projectType == .client {
                        Text("Client는 실행 시 사용 가능한 포트를 자동으로 배정합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("고정 포트", text: $state.fixedPort)
                                .textFieldStyle(.roundedBorder)
                            Text("Server는 프로젝트 추가 시 입력한 고정 포트만 사용합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("그룹") {
                    Toggle("새 그룹 만들기", isOn: $state.useNewGroup)
                    if state.useNewGroup {
                        TextField("새 그룹 이름", text: $state.newGroupName)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        HStack {
                            Text("그룹 선택")
                            Spacer()
                            Button {
                                isStackDropdownOpen = false
                                isGroupDropdownOpen.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(state.selectedGroup.isEmpty ? "없음" : state.selectedGroup)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .frame(minWidth: 170, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                            }
                            .buttonStyle(.plain)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(
                                            key: GroupDropdownAnchorPreferenceKey.self,
                                            value: proxy.frame(in: .named("addProjectRoot"))
                                        )
                                }
                            )
                        }
                    }
                }

                Section("실행 방식") {
                    Picker("", selection: $state.commandSourceType) {
                        ForEach(CommandSourceType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if state.commandSourceType == .stack {
                        HStack {
                            Text("스택")
                            Spacer()
                            Button {
                                isGroupDropdownOpen = false
                                isStackDropdownOpen.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(state.selectedStack.displayName)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .frame(minWidth: 170, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                            }
                            .buttonStyle(.plain)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(
                                            key: StackDropdownAnchorPreferenceKey.self,
                                            value: proxy.frame(in: .named("addProjectRoot"))
                                        )
                                }
                            )
                        }

                        if state.selectedStack == .custom {
                            TextField("실행 명령어", text: $state.customCommand)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            HStack {
                                Text("명령어:")
                                    .foregroundColor(.secondary)
                                Text(state.selectedStack.defaultCommand)
                                    .fontWeight(.medium)
                            }
                        }
                    } else {
                        scriptPickerRow(
                            title: "시작 스크립트",
                            selectedPath: state.scriptFileURL?.path,
                            onChoose: chooseScriptFile,
                            onClear: { state.scriptFileURL = nil }
                        )
                        scriptPickerRow(
                            title: "종료 스크립트 (선택)",
                            selectedPath: state.stopScriptFileURL?.path,
                            onChoose: chooseStopScriptFile,
                            onClear: { state.stopScriptFileURL = nil }
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("취소") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(state.isEditMode ? "저장" : "추가") {
                    onAdd(state.buildProjectConfig())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.isValid)
            }
            .padding()
        }
        .frame(minWidth: 480, maxWidth: 480, minHeight: 560)
        .coordinateSpace(name: "addProjectRoot")
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AddProjectRootSizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(GroupDropdownAnchorPreferenceKey.self) { frame in
            if frame != .zero {
                groupDropdownAnchor = frame
            }
        }
        .onPreferenceChange(StackDropdownAnchorPreferenceKey.self) { frame in
            if frame != .zero {
                stackDropdownAnchor = frame
            }
        }
        .onPreferenceChange(AddProjectRootSizePreferenceKey.self) { size in
            if size != .zero {
                rootContainerSize = size
            }
        }
        .overlay(alignment: .topLeading) {
            if isAnyDropdownOpen {
                dropdownOverlayLayer
            }
        }
        .onAppear {
            state.initializeGroupSelection(existingGroups: existingGroups)
        }
        .onChange(of: state.useNewGroup) { _, useNewGroup in
            if !useNewGroup {
                state.restoreExistingGroupSelectionIfNeeded(existingGroups: existingGroups)
            } else {
                isGroupDropdownOpen = false
            }
        }
        .onChange(of: state.commandSourceType) { _, sourceType in
            if sourceType != .stack {
                isStackDropdownOpen = false
            }
        }
    }

    private var groupOptions: [String] {
        [""] + existingGroups
    }

    private var isAnyDropdownOpen: Bool {
        isGroupDropdownOpen || isStackDropdownOpen
    }

    private var dropdownOverlayLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    isGroupDropdownOpen = false
                    isStackDropdownOpen = false
                }

            if isGroupDropdownOpen {
                let layout = dropdownLayout(
                    anchor: groupDropdownAnchor,
                    panelWidth: 220,
                    optionCount: groupOptions.count
                )
                dropdownPanel(width: layout.width, height: layout.height) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groupOptions, id: \.self) { group in
                            groupOptionButton(group)
                            if group != groupOptions.last {
                                Divider()
                            }
                        }
                    }
                }
                .offset(x: layout.x, y: layout.y)
            }

            if isStackDropdownOpen {
                let layout = dropdownLayout(
                    anchor: stackDropdownAnchor,
                    panelWidth: 240,
                    optionCount: DevStackPreset.allCases.count
                )
                dropdownPanel(width: layout.width, height: layout.height) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(DevStackPreset.allCases) { preset in
                            stackOptionButton(preset)
                            if preset.id != DevStackPreset.allCases.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .offset(x: layout.x, y: layout.y)
            }
        }
        .zIndex(999)
    }

    @ViewBuilder
    private func dropdownPanel<Content: View>(
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
        }
        .padding(6)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }

    private func dropdownLayout(anchor: CGRect, panelWidth: CGFloat, optionCount: Int) -> DropdownLayout {
        let containerWidth = max(rootContainerSize.width, 480)
        let containerHeight = max(rootContainerSize.height, 480)
        let panelPadding: CGFloat = 8
        let panelGap: CGFloat = 4
        let rowHeight: CGFloat = 32
        let dividerHeight: CGFloat = 1
        let chromeHeight: CGFloat = 12
        let desiredHeight = CGFloat(optionCount) * rowHeight
            + CGFloat(max(0, optionCount - 1)) * dividerHeight
            + chromeHeight
        let cappedDesiredHeight = min(desiredHeight, 260)

        let maxX = containerWidth - panelWidth - panelPadding
        let x = max(panelPadding, min(anchor.minX, maxX))

        let availableBelow = max(0, containerHeight - anchor.maxY - panelGap - panelPadding)
        let availableAbove = max(0, anchor.minY - panelGap - panelPadding)
        let placeAbove = cappedDesiredHeight > availableBelow && availableAbove > availableBelow

        let availableHeight = placeAbove ? availableAbove : availableBelow
        let panelHeight = max(80, min(cappedDesiredHeight, availableHeight))

        let y: CGFloat
        if placeAbove {
            y = max(panelPadding, anchor.minY - panelHeight - panelGap)
        } else {
            y = anchor.maxY + panelGap
        }

        return DropdownLayout(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    @ViewBuilder
    private func groupOptionButton(_ group: String) -> some View {
        let isSelected = state.selectedGroup == group
        Button {
            state.selectedGroup = group
            isGroupDropdownOpen = false
        } label: {
            HStack(spacing: 8) {
                Text(group.isEmpty ? "없음" : group)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stackOptionButton(_ preset: DevStackPreset) -> some View {
        let isSelected = state.selectedStack == preset
        Button {
            state.selectedStack = preset
            isStackDropdownOpen = false
        } label: {
            HStack(spacing: 8) {
                Text(preset.displayName)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scriptPickerRow(
        title: String,
        selectedPath: String?,
        onChoose: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(selectedPath ?? "선택되지 않음")
                .foregroundColor(selectedPath == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("선택...") {
                onChoose()
            }

            if selectedPath != nil {
                Button("해제") {
                    onClear()
                }
            }
        }
    }

    private func chooseDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "선택"
        openPanel.message = "프로젝트 디렉토리를 선택하세요"
        openPanel.directoryURL = state.projectPath

        presentOpenPanel(openPanel) { url in
            guard let url else { return }
            state.projectPath = url
            if state.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.projectName = url.lastPathComponent
            }
        }
    }

    private func chooseScriptFile() {
        chooseSingleFile(message: "실행할 시작 스크립트 파일을 선택하세요") { url in
            guard let url else { return }
            state.scriptFileURL = url
        }
    }

    private func chooseStopScriptFile() {
        chooseSingleFile(message: "실행할 종료 스크립트 파일을 선택하세요") { url in
            guard let url else { return }
            state.stopScriptFileURL = url
        }
    }

    private func chooseSingleFile(message: String, onSelect: @escaping (URL?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "선택"
        openPanel.message = message
        openPanel.directoryURL = state.projectPath
        presentOpenPanel(openPanel, onSelect: onSelect)
    }

    private func presentOpenPanel(_ openPanel: NSOpenPanel, onSelect: @escaping (URL?) -> Void) {
        openPanel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)

        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            openPanel.beginSheetModal(for: hostWindow) { response in
                onSelect(response == .OK ? openPanel.url : nil)
            }
            return
        }

        let response = openPanel.runModal()
        onSelect(response == .OK ? openPanel.url : nil)
    }
}

private struct DropdownLayout {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct GroupDropdownAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct StackDropdownAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct AddProjectRootSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

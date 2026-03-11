import SwiftUI

struct LogViewerView: View {
    @ObservedObject var model: LogViewModel
    let onClose: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text(model.projectName)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Toggle("자동 스크롤", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                Button(action: { model.clearLog() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("로그 지우기")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)

                Button(action: onClose) {
                    Text("닫기")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logContent.isEmpty ? " " : model.logContent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .textColor))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("logBottom")
                }
                .background(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1.0)))
                .onChange(of: model.logContent) { _, _ in
                    if autoScroll {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            if !model.isFileAvailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("로그 파일 대기 중...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

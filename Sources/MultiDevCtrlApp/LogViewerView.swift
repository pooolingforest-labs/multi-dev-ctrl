import AppKit
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

            // Log content — NSTextView for performance
            LogTextView(text: model.logContent, autoScroll: autoScroll)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1.0)))

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

// MARK: - NSTextView wrapper for efficient large-text rendering

struct LogTextView: NSViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Allow horizontal text to wrap
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.previousText = ""

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let previousText = context.coordinator.previousText

        if text.hasPrefix(previousText), text.count > previousText.count {
            // Append-only: incremental update
            let appendedPart = String(text[text.index(text.startIndex, offsetBy: previousText.count)...])
            let storage = textView.textStorage!
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
            storage.append(NSAttributedString(string: appendedPart, attributes: attrs))
        } else if text != previousText {
            // Full replacement (clear/trim)
            textView.string = text
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .textColor
        }

        context.coordinator.previousText = text

        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var textView: NSTextView?
        var previousText: String = ""
    }
}

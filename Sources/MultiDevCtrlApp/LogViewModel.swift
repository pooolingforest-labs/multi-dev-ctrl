import Foundation

@MainActor
final class LogViewModel: ObservableObject {
    @Published var logContent: String = ""
    @Published var isFileAvailable: Bool = false

    let projectName: String
    let logFileURL: URL

    private var fileHandle: FileHandle?
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let maxInitialBytes: UInt64 = 512 * 1024
    private let maxLineCount = 5000

    // Fix 2: isCancelled flag — prevents reading from closed FileHandle
    private var isCancelled = false

    // Fix 3: cancellable file watch task
    private var watchTask: Task<Void, Never>?

    // Fix 4: coalescing pending text updates
    private var pendingText: String = ""
    private var coalesceTask: Task<Void, Never>?

    init(projectName: String, logFileURL: URL) {
        self.projectName = projectName
        self.logFileURL = logFileURL
    }

    func startTailing() {
        loadInitialContent()
        startMonitoring()
    }

    func stopTailing() {
        // Fix 3: cancel file watch polling
        watchTask?.cancel()
        watchTask = nil

        // Fix 4: cancel coalescing
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingText = ""

        // Fix 2: set cancelled flag before cancelling source
        isCancelled = true
        dispatchSource?.cancel()
        dispatchSource = nil
        // Do NOT call fileHandle?.closeFile() here — the cancel handler owns the close
        fileHandle = nil
    }

    func clearLog() {
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        logContent = ""
    }

    private func loadInitialContent() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            isFileAvailable = false
            logContent = "로그 파일이 아직 없습니다. 프로젝트를 실행하면 로그가 표시됩니다."
            return
        }

        isFileAvailable = true

        do {
            let handle = try FileHandle(forReadingFrom: logFileURL)
            let fileSize = handle.seekToEndOfFile()

            if fileSize > maxInitialBytes {
                handle.seek(toFileOffset: fileSize - maxInitialBytes)
                let data = handle.readDataToEndOfFile()
                var text = String(data: data, encoding: .utf8) ?? ""
                if let firstNewline = text.firstIndex(of: "\n") {
                    text = String(text[text.index(after: firstNewline)...])
                }
                logContent = "... (이전 로그 생략) ...\n" + text
            } else {
                handle.seek(toFileOffset: 0)
                let data = handle.readDataToEndOfFile()
                logContent = String(data: data, encoding: .utf8) ?? ""
            }
            handle.closeFile()
        } catch {
            logContent = "로그 파일을 읽을 수 없습니다: \(error.localizedDescription)"
        }

        trimLines()
    }

    private func startMonitoring() {
        // Fix 2: reset cancelled flag
        isCancelled = false

        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            watchForFileCreation()
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else {
            return
        }
        handle.seekToEndOfFile()
        self.fileHandle = handle

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self, !self.isCancelled else { return }
            let newData = handle.availableData
            guard !newData.isEmpty,
                  let newText = String(data: newData, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.scheduleAppend(newText)
            }
        }

        source.setCancelHandler {
            handle.closeFile()
        }

        source.resume()
        self.dispatchSource = source
    }

    // Fix 3: cancellable file watch using structured concurrency
    private func watchForFileCreation() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { break }
                let found = await MainActor.run {
                    if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                        self.watchTask = nil
                        self.loadInitialContent()
                        self.startMonitoring()
                        return true
                    }
                    return false
                }
                if found { break }
            }
        }
    }

    // Fix 4: coalesce high-frequency updates (50ms window)
    private func scheduleAppend(_ text: String) {
        pendingText.append(text)
        guard coalesceTask == nil else { return }
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self else { return }
            let batch = self.pendingText
            self.pendingText = ""
            self.coalesceTask = nil
            self.appendAndTrim(batch)
        }
    }

    // Fix 4: append text then trim to maxLineCount
    private func appendAndTrim(_ text: String) {
        logContent.append(text)
        trimLines()
    }

    private func trimLines() {
        let lines = logContent.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLineCount else { return }
        let trimmed = lines.suffix(maxLineCount)
        logContent = "... (이전 로그 생략) ...\n" + trimmed.joined(separator: "\n")
    }
}

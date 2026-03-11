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

    init(projectName: String, logFileURL: URL) {
        self.projectName = projectName
        self.logFileURL = logFileURL
    }

    func startTailing() {
        loadInitialContent()
        startMonitoring()
    }

    func stopTailing() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fileHandle?.closeFile()
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
    }

    private func startMonitoring() {
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
            let newData = handle.availableData
            guard !newData.isEmpty,
                  let newText = String(data: newData, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.logContent.append(newText)
            }
        }

        source.setCancelHandler {
            handle.closeFile()
        }

        source.resume()
        self.dispatchSource = source
    }

    private func watchForFileCreation() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    self.loadInitialContent()
                    self.startMonitoring()
                } else {
                    self.watchForFileCreation()
                }
            }
        }
    }
}

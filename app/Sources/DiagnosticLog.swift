import Foundation

/// Append-only diagnostic logger. Writes to ~/Documents/JaSub/jasub-debug.log.
/// Thread-safe via a serial dispatch queue. No-op when isEnabled == false.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    var isEnabled: Bool = false

    private let queue = DispatchQueue(label: "tw.ultima6.jasub.diagnosticlog")
    private var fileHandle: FileHandle?

    private static let jasubDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("JaSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var logFileURL: URL { jasubDir.appendingPathComponent("jasub-debug.log") }

    private init() {
        let url = Self.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(Date().formatted(.iso8601))] \(message)\n"
        queue.async { [weak self] in
            guard let self, let fh = self.fileHandle else { return }
            fh.seekToEndOfFile()
            if let data = line.data(using: .utf8) { fh.write(data) }
        }
    }

    func sessionHeader(osVersion: String, src: String, tgt: String, device: String) {
        let sep = String(repeating: "─", count: 60)
        log(sep)
        log("Session start — macOS \(osVersion)  src=\(src)  tgt=\(tgt)  device=\(device)")
    }

    func close() {
        queue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}

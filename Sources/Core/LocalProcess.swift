import Foundation

extension Process {
    /// Last resort when a child ignores `terminate()`.
    ///
    /// On POSIX, `terminate()` sends SIGTERM, which a busy process can ignore —
    /// whisper-cli mid-inference does — so we escalate to SIGKILL. Windows has
    /// no signals: `terminate()` there is already `TerminateProcess`, which the
    /// child cannot refuse, so there is nothing to escalate to.
    func forceKill() {
        #if canImport(Darwin) || canImport(Glibc)
        kill(processIdentifier, SIGKILL)
        #else
        terminate()
        #endif
    }
}

/// A child process whose timeout/cancellation completes independently of the child.
final class LocalProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process()
                    let log = FileManager.default.temporaryDirectory.appendingPathComponent("softspoke-process-\(UUID()).log")
                    FileManager.default.createFile(atPath: log.path, contents: nil)
                    defer { try? FileManager.default.removeItem(at: log) }
                    do {
                        let output = try FileHandle(forWritingTo: log)
                        defer { try? output.close() }
                        task.executableURL = executable; task.arguments = arguments
                        task.standardInput = FileHandle.nullDevice
                        task.standardOutput = output; task.standardError = output
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] = Tools.childProcessPath
                        task.environment = environment
                        self.lock.lock()
                        if self.cancelled { self.lock.unlock(); throw CancellationError() }
                        self.process = task
                        do { try task.run() } catch { self.process = nil; self.lock.unlock(); throw error }
                        self.lock.unlock()
                        let deadline = Date().addingTimeInterval(timeout)
                        var aborted: Error?
                        while task.isRunning {
                            self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                            if cancelled { aborted = CancellationError(); break }
                            if Date() >= deadline { aborted = flowError("Transcription timed out. Your audio is saved; retry from the library."); break }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        if let aborted {
                            if task.isRunning { task.terminate() }
                            // whisper-cli mid-inference can ignore a polite
                            // request, so give it a second and then insist.
                            let grace = Date().addingTimeInterval(1)
                            while task.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                            if task.isRunning { task.forceKill() }
                            self.lock.lock(); self.process = nil; self.lock.unlock()
                            throw aborted
                        }
                        self.lock.lock(); self.process = nil; let cancelled = self.cancelled; self.lock.unlock()
                        if cancelled { throw CancellationError() }
                        let result = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                        guard task.terminationStatus == 0 else { throw flowError("Local audio processing failed: " + String(result.suffix(1500))) }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
}

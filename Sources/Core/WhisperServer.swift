import Foundation
// URLSession and URLRequest live in Foundation on Apple platforms but in
// FoundationNetworking everywhere else, including Windows.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps the large Whisper model in memory and serves phrase requests only on
/// localhost. Reusing one model process removes the startup cost at every pause.
actor WhisperServer {
    private let model: URL
    private let port: Int
    private let audioContext: Int?
    private let usesGPU: Bool
    private let detectsOnly: Bool
    private var process: Process?
    private var logHandle: FileHandle?
    private var logURL: URL?

    init(model: URL = AppPaths.largeModel, portOffset: Int = 0, audioContext: Int? = nil, usesGPU: Bool = true, detectsOnly: Bool = false) {
        self.model = model
        self.port = 18_000 + Int(ProcessInfo.processInfo.processIdentifier % 900) + portOffset
        self.audioContext = audioContext
        self.usesGPU = usesGPU
        self.detectsOnly = detectsOnly
    }

    func prepare() async throws {
        if let process, process.isRunning {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                try Task.checkCancellation()
                if !process.isRunning { break }
                if await isListening() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                try stopProcess()
                throw flowError("The local speech engine took too long to become ready.")
            }
        }
        try stopProcess()
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw flowError("The multilingual speech model is missing. Re-run Softspoke setup.")
        }

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("Softspoke-whisper-server-\(ProcessInfo.processInfo.processIdentifier)-\(port).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let task = Process()
        guard let executable = Tools.url(for: "whisper-server") else {
            throw flowError("whisper-server was not found. Install it with: brew install whisper-cpp")
        }
        task.executableURL = executable
        var arguments = [
            "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
            "-t", "6", "-bs", "1", "-bo", "1", "-nf", "-sns", "-l", "en"
        ]
        if let audioContext { arguments += ["-ac", String(audioContext)] }
        if !usesGPU { arguments.append("-ng") }
        if detectsOnly { arguments.append("-dl") }
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = handle
        task.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Tools.childProcessPath
        task.environment = environment
        try task.run()
        process = task; logHandle = handle; logURL = log

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try Task.checkCancellation()
            if !task.isRunning { throw flowError("The local speech engine stopped while starting. \(serverLog())") }
            if await isListening() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        try stopProcess()
        throw flowError("The local speech engine took too long to start.")
    }

    func transcribe(file: URL, language: String, hints: [String]) async throws -> String {
        try await prepare()
        var fields = [("response_format", "json"), ("language", language)]
        if !hints.isEmpty {
            fields.append(("prompt", hints.prefix(50).map { String($0.prefix(80)) }.joined(separator: ", ")))
        }
        let data = try await request(file: file, fields: fields)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["text"] as? String else {
            throw flowError("The local speech engine returned an unreadable transcript.")
        }
        return raw.replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectLanguage(file: URL) async throws -> LanguageDetection {
        try await prepare()
        let data = try await request(file: file, fields: [
            ("response_format", "verbose_json"),
            ("language", "auto")
        ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw flowError("The local language detector returned unreadable data.")
        }
        let language = (object["detected_language"] as? String) ?? (object["language"] as? String) ?? ""
        let confidence = object["detected_language_probability"] as? Double ?? 0
        let code = language == "romanian" ? "ro" : language == "english" ? "en" : language
        return LanguageDetection(language: code, confidence: confidence)
    }

    func stop() { try? stopProcess() }

    private func isListening() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.25
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch { return false }
    }

    private func request(file: URL, fields: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        let boundary = "Softspoke-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let audio = try Data(contentsOf: file)
        var body = Data()
        for (name, value) in fields { addField(name, value: value, boundary: boundary, to: &body) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"phrase.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw flowError("The local speech engine rejected the audio. \(String(data: data, encoding: .utf8) ?? "")")
        }
        return data
    }

    private func addField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    private func stopProcess() throws {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.forceKill() }
        }
        process = nil
        try? logHandle?.close(); logHandle = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
    }

    private func serverLog() -> String {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return String(text.suffix(800))
    }
}

import Foundation

actor StreamingDictationTranscription {
    private let transcriber: WhisperTranscription

    init(server: WhisperServer? = nil, detector: WhisperServer? = nil) {
        transcriber = WhisperTranscription(server: server, detector: detector)
    }

    func transcribe(source: URL, start: Double, duration: Double, locale: String, hints: [String]) async throws -> String {
        guard duration >= 0.5 else { return "" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Softspoke-Streaming-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = directory.appendingPathComponent("phrase.wav")
        _ = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.3f", start),
            "-t", String(format: "%.3f", duration), "-i", source.path, "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", chunk.path
        ], timeout: 20)
        do {
            return try await transcriber.transcribe(chunk, locale: locale, hints: hints) { _ in }
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("No speech") || message.localizedCaseInsensitiveContains("too short") { return "" }
            throw error
        }
    }
}

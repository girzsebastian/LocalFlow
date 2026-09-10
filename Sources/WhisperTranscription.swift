import Foundation
import AVFoundation

actor WhisperTranscription {
    static let model = AppPaths.largeModel
    static let accurateModel = model
    static let detectorModel = AppPaths.baseModel
    private let selectedModel: URL
    private let server: WhisperServer?
    private let detector: WhisperServer?
    init(model: URL? = nil, server: WhisperServer? = nil, detector: WhisperServer? = nil) {
        selectedModel = model ?? Self.model
        self.server = server
        self.detector = detector
    }
    func transcribe(_ source: URL, locale: String, hints: [String] = [], progress: @escaping @Sendable (String) async -> Void) async throws -> String {
        guard FileManager.default.fileExists(atPath: selectedModel.path) else { throw flowError("The multilingual speech model is missing. Re-run Softspoke setup.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Softspoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("audio.wav")
        await progress("Preparing audio…")
        let log = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: ["-nostdin", "-hide_banner", "-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", "-af", "silencedetect=noise=-38dB:d=0.4", "-c:a", "pcm_s16le", wav.path], timeout: 60)
        let file = try AVAudioFile(forReading: wav)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration >= 0.25 else { throw flowError("That recording was too short. Hold the shortcut while speaking, then release it.") }
        var silences: [(Double, Double)] = []
        var silenceStart: Double?
        for line in log.components(separatedBy: .newlines) {
            if let range = line.range(of: "silence_start: ") { silenceStart = Double(line[range.upperBound...].split(separator: " ").first ?? "") }
            if let range = line.range(of: "silence_end: "), let start = silenceStart, let end = Double(line[range.upperBound...].split(separator: " ").first ?? "") { silences.append((start, end)); silenceStart = nil }
        }
        if let start = silenceStart { silences.append((start, duration)) }
        let silentDuration = silences.reduce(0) { $0 + $1.1 - $1.0 }
        guard duration - silentDuration > 0.2 else { throw flowError("No speech detected. Your audio is saved.") }
        let multilingual = locale == "auto"
        // Split at real pauses so a language switch gets its own route. The
        // compact detector is restricted to English/Romanian before the large
        // model runs, preventing unrelated scripts on short accented clips.
        let planned = multilingual ? SpeechSegmentation.chunks(duration: duration, silences: silences) : [SpeechChunk(start: 0, end: duration)]
        let chunks = planned.filter { chunk in
            let silence = silences.reduce(0.0) { total, span in total + max(0, min(chunk.end, span.1) - max(chunk.start, span.0)) }
            return chunk.end - chunk.start - silence > 0.2
        }
        guard !chunks.isEmpty else { throw flowError("No speech detected. Your audio is saved.") }
        let inputs: [URL]
        if chunks.count == 1, chunks[0] == SpeechChunk(start: 0, end: duration) {
            // ffmpeg has already closed and finalized this WAV.
            inputs = [wav]
        } else {
            inputs = try chunks.enumerated().map { index, chunk in
                try Task.checkCancellation()
                let target = directory.appendingPathComponent("part-\(index).wav")
                try Self.writeChunk(source: wav, destination: target, chunk: chunk)
                return target
            }
        }
        await progress(multilingual ? "Transcribing locally · English + Romanian…" : "Transcribing locally · \(locale.hasPrefix("ro") ? "Romanian" : "English")…")
        var routes = Array(repeating: locale.hasPrefix("ro") ? "ro" : "en", count: inputs.count)
        if multilingual {
            await progress("Detecting English / Romanian phrases…")
            if let detector {
                for index in inputs.indices {
                    try Task.checkCancellation()
                    let detection = try await detector.detectLanguage(file: inputs[index])
                    routes[index] = detection.language == "ro" && detection.confidence >= 0.95 ? "ro" : "en"
                }
            } else if FileManager.default.fileExists(atPath: Self.detectorModel.path) {
                var arguments = ["-m", Self.detectorModel.path, "-l", "auto", "-dl", "-ac", "256", "-t", "4", "-bs", "1", "-bo", "1"]
                for input in inputs { arguments += ["-f", input.path] }
                let detectionLog = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"), arguments: arguments, timeout: max(30, min(300, duration + 20)))
                let detections = LanguageRouting.detections(in: detectionLog)
                for index in routes.indices where index < detections.count {
                    let detection = detections[index]
                    routes[index] = detection.language == "ro" && detection.confidence >= 0.95 ? "ro" : "en"
                }
            }
        }
        var texts = Array(repeating: "", count: inputs.count)
        for language in ["en", "ro"] {
            let indices = routes.indices.filter { routes[$0] == language }
            guard !indices.isEmpty else { continue }
            await progress("Transcribing \(language == "ro" ? "Romanian" : "English") locally…")
            if let server {
                for index in indices {
                    try Task.checkCancellation()
                    texts[index] = try await server.transcribe(file: inputs[index], language: language, hints: hints)
                }
                continue
            }
            var arguments = ["-m", selectedModel.path, "-l", language, "-otxt", "-nt", "-np", "-t", "6", "-bs", "1", "-bo", "1", "-nf", "-sns"]
            if !hints.isEmpty { arguments += ["--prompt", hints.prefix(50).map { String($0.prefix(80)) }.joined(separator: ", ")] }
            var outputs: [(Int, URL)] = []
            for index in indices {
                let output = directory.appendingPathComponent("final-\(index)")
                arguments += ["-f", inputs[index].path, "-of", output.path]
                outputs.append((index, output.appendingPathExtension("txt")))
            }
            _ = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"), arguments: arguments, timeout: max(45, min(1800, duration * 1.5 + 30)))
            for (index, output) in outputs {
                texts[index] = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let result = texts.filter { !$0.isEmpty && $0 != "[BLANK_AUDIO]" }.joined(separator: " ")
        guard !result.isEmpty else { throw flowError("No speech detected. Your audio is saved.") }
        return result
    }

    private static func writeChunk(source: URL, destination: URL, chunk: SpeechChunk) throws {
        let reader = try AVAudioFile(forReading: source)
        reader.framePosition = AVAudioFramePosition(chunk.start * 16000)
        let writer = try AVAudioFile(forWriting: destination, settings: reader.fileFormat.settings)
        var remaining = AVAudioFramePosition((chunk.end - chunk.start) * 16000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 16000) else {
            throw flowError("Could not allocate the audio buffer.")
        }
        while remaining > 0 {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(16000, remaining)))
            if buffer.frameLength == 0 { break }
            try writer.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }
}

import Foundation
import AVFoundation

actor LiveMeetingTranscription {
    static let model = AppPaths.baseModel

    enum Result { case speech(String), silence }

    func transcribe(source: URL, start: Double, duration: Double, locale: String, hints: [String]) async throws -> Result {
        guard FileManager.default.fileExists(atPath: Self.model.path) else {
            throw flowError("The small live-transcript model is missing. The final meeting recording is still safe.")
        }
        guard FileManager.default.fileExists(atPath: source.path), duration >= 1 else { return .silence }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Softspoke-Live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("chunk.wav")
        let log = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: [
            "-nostdin", "-hide_banner", "-y", "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", duration),
            "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", "-af", "silencedetect=noise=-38dB:d=0.4", "-c:a", "pcm_s16le", wav.path
        ], timeout: 20)
        let file = try AVAudioFile(forReading: wav)
        let actualDuration = Double(file.length) / file.processingFormat.sampleRate
        guard actualDuration >= 0.5 else { return .silence }
        var silences: [(Double, Double)] = [], silenceStart: Double?
        for line in log.components(separatedBy: .newlines) {
            if let range = line.range(of: "silence_start: ") { silenceStart = Double(line[range.upperBound...].split(separator: " ").first ?? "") }
            if let range = line.range(of: "silence_end: "), let begin = silenceStart,
               let end = Double(line[range.upperBound...].split(separator: " ").first ?? "") {
                silences.append((begin, end)); silenceStart = nil
            }
        }
        if let silenceStart { silences.append((silenceStart, actualDuration)) }
        let silent = silences.reduce(0.0) { $0 + $1.1 - $1.0 }
        guard actualDuration - silent > 0.3 else { return .silence }

        var spans: [(Double, Double)] = [(0, actualDuration)]
        if locale == "auto" {
            var boundaries = [0.0]
            for silence in silences where silence.1 - silence.0 >= 0.4 {
                let middle = (silence.0 + silence.1) / 2
                if middle - (boundaries.last ?? 0) >= 1.0, actualDuration - middle >= 0.4 { boundaries.append(middle) }
            }
            boundaries.append(actualDuration)
            spans = Array(zip(boundaries, boundaries.dropFirst())).filter { $0.1 - $0.0 >= 0.3 }
        }
        var inputs: [URL] = []
        for (index, span) in spans.enumerated() {
            let part = directory.appendingPathComponent("part-\(index).wav")
            let reader = try AVAudioFile(forReading: wav)
            reader.framePosition = AVAudioFramePosition(span.0 * 16000)
            let writer = try AVAudioFile(forWriting: part, settings: reader.fileFormat.settings)
            var remaining = AVAudioFramePosition((span.1 - span.0) * 16000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 16000) else { continue }
            while remaining > 0 {
                try Task.checkCancellation()
                try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(16000, remaining)))
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            inputs.append(part)
        }
        guard !inputs.isEmpty else { return .silence }
        var arguments = ["-m", Self.model.path, "-l", locale == "auto" ? "auto" : String(locale.prefix(2)),
                         "-otxt", "-nt", "-np", "-t", "4", "-bs", "1", "-bo", "1", "-nf", "-sns"]
        if !hints.isEmpty { arguments += ["--prompt", hints.prefix(30).map { String($0.prefix(60)) }.joined(separator: ", ")] }
        for input in inputs { arguments += ["-f", input.path, "-of", input.deletingPathExtension().path] }
        _ = try await LocalProcess().run(URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"), arguments: arguments, timeout: 40)
        let text = try inputs.map {
            try String(contentsOf: $0.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0 != "[BLANK_AUDIO]" }.joined(separator: " ")
        return text.isEmpty || text == "[BLANK_AUDIO]" ? .silence : .speech(text)
    }
}

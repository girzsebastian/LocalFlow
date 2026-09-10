import Foundation
import ScreenCaptureKit
import AVFoundation

final class MeetingAudio: NSObject, SystemAudioCapture, AudioMixdown, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "Softspoke.meetingAudio")
    private let destination: URL
    private var failure: Error?
    init(destination: URL) { self.destination = destination }
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw flowError("No display is available for meeting audio capture.") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        // Only register audio output. No screen frames are stored.
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        try await capture.startCapture()
    }
    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        try queue.sync {
            file = nil
            if let failure { throw failure }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.failure = error } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            var size = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
            guard size > 0 else { return }
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { pointer.deallocate() }
            let list = pointer.bindMemory(to: AudioBufferList.self, capacity: 1)
            var retained: CMBlockBuffer?
            let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained)
            guard result == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list) else { throw flowError("Could not read meeting audio.") }
            if file == nil { file = try AVAudioFile(forWriting: destination, settings: format.settings) }
            try file?.write(from: buffer)
            withExtendedLifetime(retained) {}
        } catch { failure = error }
    }
    static func mix(microphone: URL, system: URL, destination: URL) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for url in [microphone, system] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw flowError("Could not load meeting audio tracks.") }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(0.7, at: .zero); parameters.append(input)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw flowError("Could not mix the meeting recording.") }
        export.audioMix = mix
        try await export.export(to: destination, as: .m4a)
    }
}

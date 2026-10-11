import AVFoundation
import Foundation

/// Decodes any AVFoundation-readable audio or video file to 16 kHz mono.
public enum TBDAudioDecoder {
    public static let supportedExtensions: Set<String> = [
        "wav", "aif", "aiff", "caf", "m4a", "mp3", "aac", "flac", "mp4", "mov", "m4v", "3gp", "amr", "ogg", "opus", "webm",
    ]

    /// Streams the audio track of `source` into a 16 kHz mono WAV at `destination`. Returns the duration in ms.
    @discardableResult
    public static func decodeToWAV(_ source: URL, destination: URL,
                                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TBDSpeechError.audioUnreadable("\(source.lastPathComponent) has no audio track") }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TBDSpeechError.audioUnreadable("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw TBDSpeechError.audioUnreadable(reader.error?.localizedDescription ?? "cannot read \(source.lastPathComponent)")
        }
        let writer = try TBDWAVWriter(url: destination)
        defer { try? writer.close() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { writer.append(floats) }
            if duration > 0 { progress?(min(1, Double(writer.durationMs) / 1000 / duration)) }
        }
        if reader.status == .failed {
            throw TBDSpeechError.audioUnreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        try writer.close()
        guard writer.samplesWritten > 0 else { throw TBDSpeechError.audioUnreadable("\(source.lastPathComponent) contains no audio") }
        return writer.durationMs
    }

    /// Reads a (short) file fully into 16 kHz mono samples.
    public static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TBDSpeechError.audioUnreadable("buffer allocation failed")
        }
        try file.read(into: buffer)
        return TBDMonoResampler().convert(buffer)
    }

    /// Duration of an audio file in ms, or 0.
    public static func durationMs(of url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Int(Double(file.length) / file.fileFormat.sampleRate * 1000)
    }
}

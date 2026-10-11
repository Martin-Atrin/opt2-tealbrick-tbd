import AVFoundation
import Foundation

/// Converts arbitrary capture buffers to 16 kHz mono Float32 samples.
/// Not thread safe: use one instance per capture stream (tap callbacks are serial).
public final class TBDMonoResampler {
    public static let sampleRate: Double = 16_000
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TBDMonoResampler.sampleRate,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let mono = Self.downmix(buffer) else { return [] }
        if mono.format.sampleRate == Self.sampleRate { return Self.samples(mono) }
        if sourceFormat?.isEqual(mono.format) != true {
            converter = AVAudioConverter(from: mono.format, to: output)
            // Live chunks cannot provide read-ahead frames; prime-less mode avoids withholding output.
            converter?.primeMethod = .none
            sourceFormat = mono.format
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * Self.sampleRate / mono.format.sampleRate).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        // `.inputRanDry` still carries valid partial output (common for 24 kHz Bluetooth input).
        switch status {
        case .haveData, .inputRanDry: return Self.samples(out)
        default: return []
        }
    }

    /// Averages all channels into one Float32 channel. Mono Float32 input is returned unchanged.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }
        if channels == 1 && format.commonFormat == .pcmFormatFloat32 { return buffer }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        let scale = 1 / Float(channels)
        let interleaved = format.isInterleaved
        func mix<T>(_ data: UnsafePointer<UnsafeMutablePointer<T>>, _ value: (T) -> Float) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved ? value(data[0][frame * channels + channel]) : value(data[channel][frame])
                }
                out[frame] = sum * scale
            }
        }
        if let data = buffer.floatChannelData { mix(data) { $0 } }
        else if let data = buffer.int16ChannelData { mix(data) { Float($0) / 32_768 } }
        else if let data = buffer.int32ChannelData { mix(data) { Float($0) / 2_147_483_648 } }
        else { return nil }
        return mono
    }

    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

public enum TBDAudioLevel {
    /// Root mean square of `samples`.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A 0...1 display level with the same scaling the overlay waveform expects.
    public static func normalized(_ samples: [Float]) -> Float { min(rms(samples[...]) * 5, 1) }
}

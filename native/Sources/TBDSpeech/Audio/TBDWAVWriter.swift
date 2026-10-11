import Foundation

/// Crash-safe 16-bit PCM WAV writer. The header sizes are patched every few seconds, and
/// `repairHeader(at:)` rebuilds them from the file length after a crash.
public final class TBDWAVWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int
    private let handle: FileHandle
    private let lock = NSLock()
    private var dataBytes: UInt32 = 0
    private var pending = Data()
    private var lastPatch = Date()
    private var closed = false

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0, sampleRate: sampleRate),
                                       attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? close() }

    public var samplesWritten: Int { lock.lock(); defer { lock.unlock() }; return Int(dataBytes) / 2 }
    public var durationMs: Int { samplesWritten * 1000 / sampleRate }

    /// Appends Float samples in -1...1. Data reaches disk at least every two seconds.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.reserveCapacity(pending.count + samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32_767)
            withUnsafeBytes(of: value.littleEndian) { pending.append(contentsOf: $0) }
        }
        dataBytes &+= UInt32(samples.count * 2)
        if pending.count >= sampleRate * 2 || Date().timeIntervalSince(lastPatch) > 2 { flushLocked(patch: true) }
    }

    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        flushLocked(patch: true)
        closed = true
        try handle.close()
    }

    private func flushLocked(patch: Bool) {
        if !pending.isEmpty { handle.write(pending); pending.removeAll(keepingCapacity: true) }
        guard patch else { return }
        Self.patchSizes(handle: handle, dataBytes: dataBytes)
        _ = try? handle.seekToEnd()
        try? handle.synchronize()
        lastPatch = Date()
    }

    static func header(dataBytes: UInt32, sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }

    private static func patchSizes(handle: FileHandle, dataBytes: UInt32) {
        func write(_ value: UInt32, at offset: UInt64) {
            try? handle.seek(toOffset: offset)
            withUnsafeBytes(of: value.littleEndian) { handle.write(Data($0)) }
        }
        write(36 &+ dataBytes, at: 4)
        write(dataBytes, at: 40)
    }

    /// Rebuilds the size fields of a WAV written by this class from the file length. Returns the duration in ms.
    @discardableResult
    public static func repairHeader(at url: URL, sampleRate: Int = 16_000) throws -> Int {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= 44 else { throw TBDSpeechError.audioUnreadable("recording is empty") }
        // Only touch files with exactly the layout this writer produces.
        let reader = try FileHandle(forReadingFrom: url)
        let head = try reader.read(upToCount: 44) ?? Data()
        try reader.close()
        let expected = header(dataBytes: 0, sampleRate: sampleRate)
        guard head.count == 44, head[0..<4] == expected[0..<4], head[8..<40] == expected[8..<40] else {
            throw TBDSpeechError.audioUnreadable("not a Listening recording")
        }
        let dataBytes = UInt32(min(UInt64(UInt32.max - 36), (size - 44) & ~1))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        patchSizes(handle: handle, dataBytes: dataBytes)
        return Int(dataBytes / 2) * 1000 / sampleRate
    }
}

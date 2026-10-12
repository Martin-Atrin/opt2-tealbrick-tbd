import Foundation

/// Minimal ZIP archive writer (stored entries, no compression). Enough for OOXML packages such
/// as DOCX, which only require a valid local header, data and central directory per part.
public struct TBDZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    /// Adds a file at `path` (forward slashes, no leading slash).
    public mutating func add(_ path: String, _ contents: Data) {
        let name = Array(path.utf8)
        let crc = Self.crc32(contents)
        let offset = UInt32(data.count)
        // Local file header.
        append32(0x0403_4B50)
        append16(20)              // version needed
        append16(0x0800)          // flags: UTF-8 names
        append16(0)               // method: stored
        append16(0); append16(0x21) // mod time, mod date (1980-01-01)
        append32(crc)
        append32(UInt32(contents.count)); append32(UInt32(contents.count))
        append16(UInt16(name.count)); append16(0)
        data.append(contentsOf: name)
        data.append(contents)
        entries.append(Entry(name: name, crc: crc, size: UInt32(contents.count), offset: offset))
    }

    public mutating func add(_ path: String, _ text: String) { add(path, Data(text.utf8)) }

    /// The finished archive.
    public func finish() -> Data {
        var out = self
        let directoryStart = UInt32(out.data.count)
        for entry in entries {
            out.append32(0x0201_4B50)
            out.append16(20); out.append16(20)
            out.append16(0x0800); out.append16(0)
            out.append16(0); out.append16(0x21)
            out.append32(entry.crc)
            out.append32(entry.size); out.append32(entry.size)
            out.append16(UInt16(entry.name.count))
            out.append16(0); out.append16(0)   // extra, comment
            out.append16(0); out.append16(0)   // disk, internal attributes
            out.append32(0)                    // external attributes
            out.append32(entry.offset)
            out.data.append(contentsOf: entry.name)
        }
        let directorySize = UInt32(out.data.count) - directoryStart
        out.append32(0x0605_4B50)
        out.append16(0); out.append16(0)
        out.append16(UInt16(entries.count)); out.append16(UInt16(entries.count))
        out.append32(directorySize)
        out.append32(directoryStart)
        out.append16(0)
        return out.data
    }

    private mutating func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    private mutating func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// Reads the entries of a stored archive written by this type (tests and verification).
    public static func entries(in archive: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        let bytes = [UInt8](archive)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var index = 0
        while index + 30 <= bytes.count, u32(index) == 0x0403_4B50 {
            let size = u32(index + 18)
            let nameLength = u16(index + 26)
            let extra = u16(index + 28)
            let nameStart = index + 30
            guard nameStart + nameLength + extra + size <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            let dataStart = nameStart + nameLength + extra
            result[name] = Data(bytes[dataStart..<dataStart + size])
            index = dataStart + size
        }
        return result
    }
}

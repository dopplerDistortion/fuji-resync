import Foundation

/// Little-endian byte writer used for every PTP payload (USB and Wi-Fi share the same layout).
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func bytes(_ d: Data) { data.append(d) }

    /// PTP string: UInt8 character count (including the trailing NUL), then UTF-16LE code units.
    /// An empty string is a single zero byte.
    public mutating func ptpString(_ s: String) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16.prefix(254))
        u8(UInt8(units.count + 1))
        units.forEach { u16($0) }
        u16(0)
    }
}

public enum ByteReaderError: Error, Equatable {
    case outOfBounds(offset: Int, need: Int, have: Int)
}

/// Little-endian byte reader with bounds checking.
public struct ByteReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = Data(data) // re-base indices at 0
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard remaining >= n else { throw ByteReaderError.outOfBounds(offset: offset, need: n, have: remaining) }
        defer { offset += n }
        return data.subdata(in: offset ..< offset + n)
    }

    public mutating func u8() throws -> UInt8 { try take(1)[0] }
    public mutating func u16() throws -> UInt16 {
        let b = try take(2); return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32()); let hi = UInt64(try u32()); return lo | hi << 32
    }
    public mutating func bytes(_ n: Int) throws -> Data { try take(n) }
    public mutating func rest() -> Data { (try? take(remaining)) ?? Data() }

    public mutating func ptpString() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0 ..< count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

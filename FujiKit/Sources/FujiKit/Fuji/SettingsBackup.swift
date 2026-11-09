import Foundation

/// The camera's settings backup (`backup.dat`) as the X-T30 II sends it over Bluetooth.
///
/// Found on a real X-T30 II (firmware 2.04), 2026-11-09:
/// - the file arrives zlib-compressed (`78 9c`) and inflates to the size `information` reports (38,780 bytes)
/// - it starts `FUJIFILMX-BACKUP` + format `0100` + the model name, then the serial at 0x34
/// - C1–C7 are records 0x400 apart; the slot name (NUL-terminated) sits at 0x7cfb + n·0x400 and
///   about 90 setting bytes start 0x17f before it. Which byte is which setting is still unmapped.
public struct SettingsBackup: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public let slot: Int
        public let name: String
        /// The slot's undecoded setting bytes.
        public let settings: Data
    }

    public let format: String
    public let model: String
    public let serial: String
    public let slots: [Slot]
    /// The inflated file.
    public let raw: Data

    public enum Failure: Error, Equatable {
        case notZlib
        case corrupt
        case notABackup
        case unknownLayout(model: String, format: String)
    }

    static let magic = Data("FUJIFILMX-BACKUP".utf8)
    /// Layouts seen so far, by model and format.
    static let layouts: [String: (firstName: Int, stride: Int, settingsBefore: Int, settingsLength: Int, size: Int)] = [
        "X-T30 II/0100": (0x7cfb, 0x400, 0x17f, 0x60, 38_780),
    ]

    /// Parses the file the camera sent, compressed or not.
    public init(_ file: Data) throws {
        let raw = file.starts(with: [0x78]) ? try Self.inflate(file) : Data(file)
        guard raw.count >= 0x60, raw.starts(with: Self.magic) else { throw Failure.notABackup }
        let b = Array(raw)
        func text(_ from: Int, _ max: Int) -> String {
            let end = min(from + max, b.count)
            return String(decoding: b[from ..< end].prefix { $0 != 0 }, as: UTF8.self)
        }
        format = text(0x10, 4)
        model = text(0x14, 0x20)
        serial = text(0x34, 0x20)
        guard let l = Self.layouts["\(model)/\(format)"], raw.count >= l.size else {
            throw Failure.unknownLayout(model: model, format: format)
        }
        slots = (0 ..< 7).map { i in
            let at = l.firstName + i * l.stride
            let s = at - l.settingsBefore
            return Slot(slot: i + 1, name: text(at, 0x20), settings: Data(b[s ..< min(s + l.settingsLength, b.count)]))
        }
        self.raw = raw
    }

    /// Inflates a zlib stream (RFC 1950: 2-byte header, deflate, Adler-32) and checks the Adler-32.
    public static func inflate(_ z: Data) throws -> Data {
        let b = Array(z)
        guard b.count > 6, b[0] & 0x0f == 8, (UInt16(b[0]) << 8 | UInt16(b[1])) % 31 == 0, b[1] & 0x20 == 0 else { throw Failure.notZlib }
        // Apple's .zlib is raw deflate, so strip the zlib wrapper.
        let body = Data(b[2 ..< b.count - 4]) as NSData
        guard let out = try? body.decompressed(using: .zlib) as Data else { throw Failure.corrupt }
        let want = b.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard adler32(out) == want else { throw Failure.corrupt }
        return out
    }

    static func adler32(_ d: Data) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; s = (s + a) % 65521 }
        return s << 16 | a
    }

    /// Wraps raw bytes as a zlib stream, for tests and fixtures.
    static func deflate(_ d: Data) throws -> Data {
        var out = Data([0x78, 0x9c])
        out.append(try (d as NSData).compressed(using: .zlib) as Data)
        let a = adler32(d)
        out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 0xff), UInt8(a >> 8 & 0xff), UInt8(a & 0xff)])
        return out
    }
}

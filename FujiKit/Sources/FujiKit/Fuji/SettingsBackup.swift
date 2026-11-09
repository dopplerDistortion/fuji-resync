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

/// Reads a recipe out of a slot's setting bytes (X-T30 II, format 0100).
///
/// Mapped on 2026-11-09 by lining up a Bluetooth dump against a USB read of the same seven slots.
/// Offsets are into `Slot.settings`. Values seen in only some slots are marked; anything not
/// mapped keeps the recipe default and is listed in `unmapped`, so a caller never shows a guess
/// as the camera's value.
///
/// | offset | setting | encoding |
/// |---|---|---|
/// | 0x00 | colour temperature | u16 LE, Kelvin |
/// | 0x28 | WB mode | 0 auto, 1 white priority, 10 Kelvin (others unseen) |
/// | 0x29 + 2k | WB shift for mode k | (9 − red, 9 − blue); k in menu order: auto, white priority, ambience, custom 1–3, K, … |
/// | 0x46 | clarity | clarity + 6 |
/// | 0x4a | film simulation | see `filmCodes` (only five seen) |
/// | 0x50 / 0x51 | mono warm-cool / magenta-green | 18 − value (warm-cool seen once) |
/// | 0x52 | dynamic range | 0 auto, 2 DR200, 3 DR400 (1 DR100 assumed) |
/// | 0x54 | colour | 7 − colour |
/// | 0x55 | sharpness | 4 − sharpness |
/// | 0x56 / 0x57 | highlight / shadow | (tone + 2) × 2 |
/// | 0x58 / 0x59 | colour chrome / FX blue | 0 off, 1 weak, 2 strong |
///
/// Not mapped yet: grain (0x5a–0x5c change with it but don't fit one encoding), noise reduction
/// (−4 in every slot), smooth skin.
public extension SettingsBackup.Slot {
    static let filmCodes: [UInt8: FilmSimulation] = [
        2: .astia, 4: .velvia, 15: .classicChrome, 16: .classicNeg, 21: .acrosRed,
    ]
    /// Position of each WB mode in the shift table.
    static let wbModes: [UInt8: (WhiteBalance, k: Int)] = [
        0: (.auto, 0), 1: (.autoWhitePriority, 1), 10: (.kelvin, 6),
    ]
    static let unmappedAlways = ["grain", "noise reduction", "smooth skin"]

    func decode() -> (recipe: Recipe, unmapped: [String]) {
        let b = Array(settings)
        var r = Recipe(name: name.isEmpty ? "C\(slot)" : name)
        r.source = "camera C\(slot) · bluetooth"
        var unmapped = Self.unmappedAlways
        guard b.count >= 0x5a else { return (r, ["everything"]) }

        if let s = Self.filmCodes[b[0x4a]] { r.filmSimulation = s } else { unmapped.append("film simulation (code \(b[0x4a]))") }
        switch b[0x52] {
        case 0: r.dynamicRange = .auto
        case 1: r.dynamicRange = .dr100
        case 2: r.dynamicRange = .dr200
        case 3: r.dynamicRange = .dr400
        default: unmapped.append("dynamic range (code \(b[0x52]))")
        }
        if let mode = Self.wbModes[b[0x28]] {
            let k = mode.k
            r.whiteBalance = mode.0
            r.wbShiftRed = 9 - Int(b[0x29 + 2 * k])
            r.wbShiftBlue = 9 - Int(b[0x2a + 2 * k])
        } else {
            unmapped.append("white balance (code \(b[0x28]))")
        }
        let kelvin = Int(b[0]) | Int(b[1]) << 8
        if r.whiteBalance == .kelvin, kelvin >= 2500 { r.kelvin = kelvin }
        r.clarity = Int(b[0x46]) - 6
        r.color = 7 - Int(b[0x54])
        r.sharpness = 4 - Int(b[0x55])
        r.highlight = Double(b[0x56]) / 2 - 2
        r.shadow = Double(b[0x57]) / 2 - 2
        if let s = EffectStrength(code: UInt16(b[0x58]) + 1) { r.colorChrome = s }
        if let s = EffectStrength(code: UInt16(b[0x59]) + 1) { r.colorChromeBlue = s }
        if r.filmSimulation.isMonochrome {
            r.monoWarmCool = 18 - Int(b[0x50])
            r.monoMagentaGreen = 18 - Int(b[0x51])
            r.color = 0
        }
        return (r.normalized(), unmapped)
    }
}

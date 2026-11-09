import XCTest
@testable import FujiKit

/// The setting bytes of C1–C7 from a real X-T30 II's Bluetooth backup, checked against a USB read
/// of the same slots taken a minute earlier (2026-11-09). Only the slot bytes: no serial.
final class SettingsBackupDecodeTests: XCTestCase {
    static let rows = [
        "1c0c150018001c00230032004b0000000001010201000000000100000302020202000001000000030a0909090909090b060909090901110909090909090909090909090909000400010210001514090912120204080505070100010002070700",
        "1027150018001c00230032004b00000001010102010000000001000003020202020000010000000300070d090909090909090909090909090909090909090909090909090900060001020f001514090912120304050602020201010002070700",
        "1027150018001c00230032004b00000000010102010000000001000001020202020000010000000301070d070d090909090909090909090909090909090909090909090909000402020202001514090912120204040501020201010002070700",
        "1c0c150018001c00230032004b0000000001010201000000000100000002030000000001000000030a080c070d090909090909090901110909090909090909090909090f06000600010210001514090912120204060605070100010002070700",
        "1c0c150018001c00230032004b0000000001010201000000000100000002030000000001000000030a0909070d09090909090909090111070e090909090909090909090f06000400010215001514090910120204050505070000000102070700",
        "1027150018001c00230032004b00000000010102010000000001000001020300000000010000000301070d0909090909090909090909090311090909090909090909090f06000200010204001514090912120204030402020200010002070700",
        "1027150018001c00230032004b00000000010102010000000001000000020202020000010000000301070d070f09090909090909090909090909090909090909090909090900040001020f001514090912120003050602020202000003070700",
    ]

    /// What the USB read said, for the fields the Bluetooth bytes carry.
    struct Want {
        var film: FilmSimulation, dr: DynamicRange, wb: WhiteBalance, kelvin: Int?, red: Int, blue: Int
        var hl: Double, sh: Double, color: Int, sharp: Int, clarity: Int, cc: EffectStrength, ccb: EffectStrength, wc: Int
    }

    static let want: [Want] = [
        .init(film: .classicNeg, dr: .dr200, wb: .kelvin, kelvin: 3100, red: 8, blue: -8, hl: 0.5, sh: 1.5, color: -1, sharp: -1, clarity: -2, cc: .weak, ccb: .off, wc: 0),
        .init(film: .classicChrome, dr: .dr400, wb: .auto, kelvin: nil, red: 2, blue: -4, hl: -1, sh: -1, color: 2, sharp: -2, clarity: 0, cc: .strong, ccb: .weak, wc: 0),
        .init(film: .astia, dr: .dr200, wb: .autoWhitePriority, kelvin: nil, red: 2, blue: -4, hl: -1.5, sh: -1, color: 3, sharp: -1, clarity: -2, cc: .strong, ccb: .weak, wc: 0),
        .init(film: .classicNeg, dr: .dr200, wb: .kelvin, kelvin: 3100, red: 8, blue: -8, hl: 0.5, sh: 1.5, color: 1, sharp: -2, clarity: 0, cc: .weak, ccb: .off, wc: 0),
        .init(film: .acrosRed, dr: .dr200, wb: .kelvin, kelvin: 3100, red: 8, blue: -8, hl: 0.5, sh: 1.5, color: 0, sharp: -1, clarity: -2, cc: .off, ccb: .off, wc: 2),
        .init(film: .velvia, dr: .dr200, wb: .autoWhitePriority, kelvin: nil, red: 0, blue: 0, hl: -1, sh: -1, color: 4, sharp: 0, clarity: -4, cc: .strong, ccb: .off, wc: 0),
        .init(film: .classicChrome, dr: .auto, wb: .autoWhitePriority, kelvin: nil, red: 2, blue: -6, hl: -1, sh: -1, color: 2, sharp: -2, clarity: -2, cc: .strong, ccb: .strong, wc: 0),
    ]

    private func bytes(_ hex: String) -> Data {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); d.append(UInt8(hex[i ..< j], radix: 16)!); i = j }
        return d
    }

    func testEverySlotMatchesTheUSBRead() {
        for (n, (hex, w)) in zip(Self.rows, Self.want).enumerated() {
            let slot = SettingsBackup.Slot(slot: n + 1, name: "C\(n + 1)", settings: bytes(hex))
            let (r, unmapped) = slot.decode()
            let c = "c\(n + 1)"
            XCTAssertEqual(r.filmSimulation, w.film, c)
            XCTAssertEqual(r.dynamicRange, w.dr, c)
            XCTAssertEqual(r.whiteBalance, w.wb, c)
            if let k = w.kelvin { XCTAssertEqual(r.kelvin, k, c) }
            XCTAssertEqual(r.wbShiftRed, w.red, c)
            XCTAssertEqual(r.wbShiftBlue, w.blue, c)
            XCTAssertEqual(r.highlight, w.hl, c)
            XCTAssertEqual(r.shadow, w.sh, c)
            XCTAssertEqual(r.color, w.color, c)
            XCTAssertEqual(r.sharpness, w.sharp, c)
            XCTAssertEqual(r.clarity, w.clarity, c)
            XCTAssertEqual(r.colorChrome, w.cc, c)
            XCTAssertEqual(r.colorChromeBlue, w.ccb, c)
            XCTAssertEqual(r.monoWarmCool, w.wc, c)
            XCTAssertEqual(unmapped, SettingsBackup.Slot.unmappedAlways, c)
        }
    }

    func testAnUnseenFilmCodeIsReportedNotGuessed() {
        var d = bytes(Self.rows[0]); d[0x4a] = 99
        let (_, unmapped) = SettingsBackup.Slot(slot: 1, name: "x", settings: d).decode()
        XCTAssertTrue(unmapped.contains("film simulation (code 99)"))
    }
}

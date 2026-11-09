import XCTest
@testable import FujiKit

final class SettingsBackupTests: XCTestCase {
    /// A file shaped like the X-T30 II's: header, serial, seven named slots. No real camera data.
    private func fakeBackup(model: String = "X-T30 II") -> Data {
        var b = [UInt8](repeating: 0, count: 38_780)
        func put(_ s: String, _ at: Int) { for (i, c) in s.utf8.enumerated() { b[at + i] = c } }
        put("FUJIFILMX-BACKUP0100", 0)
        put(model, 0x14)
        put("0000000000000000000", 0x34)
        for i in 0 ..< 7 {
            let at = 0x7cfb + i * 0x400
            put("SLOT \(i + 1)", at)
            b[at - 0x17f] = UInt8(0x10 + i)
        }
        return Data(b)
    }

    func testInflatesAndReadsHeaderAndSlots() throws {
        let raw = fakeBackup()
        let z = try SettingsBackup.deflate(raw)
        XCTAssertEqual(Array(z.prefix(2)), [0x78, 0x9c])
        let s = try SettingsBackup(z)
        XCTAssertEqual(s.raw, raw)
        XCTAssertEqual(s.format, "0100")
        XCTAssertEqual(s.model, "X-T30 II")
        XCTAssertEqual(s.serial, "0000000000000000000")
        XCTAssertEqual(s.slots.map(\.name), (1 ... 7).map { "SLOT \($0)" })
        XCTAssertEqual(s.slots.map { $0.settings.first }, (0 ..< 7).map { UInt8(0x10 + $0) })
        XCTAssertEqual(s.slots.last?.settings.count, 0x60)
    }

    func testRejectsADamagedStream() throws {
        var z = try SettingsBackup.deflate(fakeBackup())
        z[z.count - 1] ^= 0xff // Adler-32
        XCTAssertThrowsError(try SettingsBackup(z))
    }

    func testUnknownModelIsReportedNotGuessed() throws {
        XCTAssertThrowsError(try SettingsBackup(fakeBackup(model: "X-T5"))) { e in
            XCTAssertEqual(e as? SettingsBackup.Failure, .unknownLayout(model: "X-T5", format: "0100"))
        }
    }

    func testAdler32() {
        XCTAssertEqual(SettingsBackup.adler32(Data("Wikipedia".utf8)), 0x11E6_0398)
    }
}

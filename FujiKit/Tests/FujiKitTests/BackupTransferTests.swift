import XCTest
@testable import FujiKit

final class BackupTransferTests: XCTestCase {
    private func piece(_ seq: UInt16, _ body: [UInt8]) -> Data {
        var w = ByteWriter()
        w.u16(seq)
        w.u32(UInt32(body.count))
        w.bytes(Data(body))
        return w.data
    }

    func testAssemblesPiecesAndChecksTheSum() throws {
        var a = FujiBLE.Backup.Assembler()
        let first = try a.add(piece(0, [1, 2, 3]))
        let second = try a.add(piece(1, [250, 250]))
        // Last piece: data then u16 sum of every data byte (1+2+3+250+250+4 = 510 = 0x01fe).
        let last = try a.add(piece(0xFFFF, [4, 0xfe, 0x01]))
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertTrue(last)
        XCTAssertEqual(Array(a.data), [1, 2, 3, 250, 250, 4])
        XCTAssertEqual(a.pieces, 3)
        XCTAssertTrue(a.isComplete)
        XCTAssertNoThrow(try a.verify())
    }

    func testABadSumIsReported() throws {
        var a = FujiBLE.Backup.Assembler()
        try a.add(piece(0, [9]))
        try a.add(piece(0xFFFF, [0x00, 0x00]))
        XCTAssertThrowsError(try a.verify()) { e in
            XCTAssertEqual(e as? FujiBLE.Backup.Failure, .checksum(expected: 0, got: 9))
        }
    }

    func testTheSumWrapsAtSixteenBits() throws {
        var a = FujiBLE.Backup.Assembler()
        let body = [UInt8](repeating: 0xff, count: 300) // 76,500 → 0x2ad4
        try a.add(piece(0, body))
        try a.add(piece(0xFFFF, [0xd4, 0x2a]))
        XCTAssertNoThrow(try a.verify())
    }

    func testRejectsAShortOrLyingPiece() {
        var a = FujiBLE.Backup.Assembler()
        var w = ByteWriter(); w.u16(0); w.u32(10); w.bytes(Data([1, 2]))
        for bad in [Data([0, 0, 5]), w.data] {
            do { try a.add(bad); XCTFail("accepted \(bad.hex)") } catch {}
        }
    }

    func testInformationAndTrim() {
        var info = Data("backup.dat".utf8)
        info.append(Data(count: 40 - info.count))
        var w = ByteWriter(); w.u32(4)
        info.append(w.data)
        let parsed = FujiBLE.Backup.information(info)
        XCTAssertEqual(parsed?.name, "backup.dat")
        XCTAssertEqual(parsed?.size, 4)

        var a = FujiBLE.Backup.Assembler()
        _ = try? a.add(piece(0xFFFF, [1, 2, 3, 4, 5, 6, 0x15, 0x00]))
        XCTAssertEqual(Array(a.file(size: 4)), [1, 2, 3, 4])
        XCTAssertEqual(a.file(size: nil).count, 6)
        XCTAssertEqual(a.file(size: 99).count, 6)
    }

    func testStateCode() {
        XCTAssertEqual(FujiBLE.Backup.stateCode(Data([0x03, 0x00])), 3)
        XCTAssertEqual(FujiBLE.Backup.stateCode(Data([0x05, 0x00, 0xff, 0xff])), 5)
        XCTAssertEqual(FujiBLE.Backup.stateCode(Data([0x01])), 1)
        XCTAssertNil(FujiBLE.Backup.stateCode(Data()))
    }
}

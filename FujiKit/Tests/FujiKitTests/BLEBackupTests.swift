import XCTest
@testable import FujiKit

final class BLEBackupTests: XCTestCase {
    private typealias C = FujiBLEBackup.Characteristic

    private func chunk(seq: UInt16, _ payload: [UInt8]) -> Data {
        var w = ByteWriter()
        w.u16(seq)
        w.u32(UInt32(payload.count))
        w.bytes(Data(payload))
        return w.data
    }

    func testFullDownloadChecksSumAndTrimsToReportedSize() {
        var d = FujiBLEBackup.Download()
        let start = d.start(available: C.all)
        XCTAssertEqual(start.last, .write(C.backupRequest, Data([1, 0])))
        XCTAssertEqual(d.receive(Data([1]), from: C.backupState).count, 2)
        XCTAssertEqual(d.receive(Data([1, 0]), from: C.fileTransactionState), [.read(C.filePartialData)])
        _ = d.receive(chunk(seq: 0, [1, 2, 3]), from: C.filePartialData)
        _ = d.receive(Data([2, 0]), from: C.fileTransactionState)
        // Last piece: 4, 5, then the u16 sum of 1…5 = 15.
        _ = d.receive(chunk(seq: 0xFFFF, [4, 5, 15, 0]), from: C.filePartialData)
        XCTAssertEqual(d.receive(Data([3, 0]), from: C.fileTransactionState), [.read(C.fileInformation)])

        var info = Data("backup.dat".utf8)
        info.append(Data(count: 40 - info.count))
        info.append(contentsOf: [4, 0, 0, 0])
        let end = d.receive(info, from: C.fileInformation)
        XCTAssertEqual(end.first, .write(C.fileTransferResult, Data([3, 0])))
        guard case let .finished(r)? = end.last else { return XCTFail("not finished: \(end)") }
        XCTAssertEqual(r.name, "backup.dat")
        XCTAssertEqual(r.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(r.checksum, 15)
        XCTAssertEqual(d.chunks, 2)
    }

    func testBadChecksumFailsAndAbortsTransfer() {
        var d = FujiBLEBackup.Download()
        _ = d.start(available: C.all)
        _ = d.receive(Data([1]), from: C.backupState)
        _ = d.receive(chunk(seq: 0xFFFF, [9, 1, 0]), from: C.filePartialData)
        let out = d.receive(Data([3, 0]), from: C.fileTransactionState)
        XCTAssertEqual(out.first, .write(C.fileTransferResult, Data([0, 0])))
        XCTAssertEqual(d.phase, .failed)
    }

    func testBusyCameraFails() {
        var d = FujiBLEBackup.Download()
        _ = d.start(available: C.all)
        let out = d.receive(Data([0]), from: C.backupState)
        guard case .failed? = out.last else { return XCTFail("\(out)") }
    }

    func testMissingServiceIsUnsupported() {
        var d = FujiBLEBackup.Download()
        let out = d.start(available: [C.backupRequest])
        XCTAssertEqual(out.count, 1)
        guard case .failed? = out.first else { return XCTFail("\(out)") }
    }

    func testMalformedChunkFails() {
        var d = FujiBLEBackup.Download()
        _ = d.start(available: C.all)
        _ = d.receive(Data([1]), from: C.backupState)
        let out = d.receive(Data([0, 0, 99, 0, 0, 0, 1]), from: C.filePartialData)
        guard case .failed? = out.last else { return XCTFail("\(out)") }
    }
}

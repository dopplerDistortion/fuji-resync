import XCTest
@testable import FujiKit

final class AccessTests: XCTestCase {
    private func backup(serial: String?, origin: CameraBackup.Origin = .thisApp) -> CameraBackup {
        CameraBackup(cameraSerial: serial, origin: origin,
                     slots: (1 ... 7).map { CameraBackup.Slot(slot: $0, name: "C\($0)", recipe: Recipe(name: "r\($0)")) })
    }

    func testFreeWritesOnlyC1() {
        XCTAssertTrue(Access.canWrite(slot: 1, tier: .free))
        for n in 2 ... 7 { XCTAssertFalse(Access.canWrite(slot: n, tier: .free), "c\(n)") }
    }

    func testSubscriberWritesEverySlotAndNothingElse() {
        for n in 1 ... 7 { XCTAssertTrue(Access.canWrite(slot: n, tier: .subscriber), "c\(n)") }
        XCTAssertFalse(Access.canWrite(slot: 0, tier: .subscriber))
        XCTAssertFalse(Access.canWrite(slot: 8, tier: .subscriber))
    }

    func testFreeRestoresOwnCameraBackupToEverySlot() {
        let b = backup(serial: "12345")
        XCTAssertEqual(Access.restorableSlots(of: b, toCamera: "12345", tier: .free), Array(1 ... 7))
    }

    func testFreeRestoresOnlyC1FromAnotherCamera() {
        let b = backup(serial: "12345")
        XCTAssertEqual(Access.restorableSlots(of: b, toCamera: "99999", tier: .free), [1])
    }

    func testFreeRestoresOnlyC1FromAnImportedFile() {
        let b = backup(serial: "12345", origin: .imported)
        XCTAssertEqual(Access.restorableSlots(of: b, toCamera: "12345", tier: .free), [1])
    }

    func testUnknownSerialCountsAsOwnCameraForThisAppsBackups() {
        XCTAssertEqual(Access.restorableSlots(of: backup(serial: nil), toCamera: nil, tier: .free), Array(1 ... 7))
    }

    func testSubscriberRestoresAnything() {
        let b = backup(serial: "12345", origin: .imported)
        XCTAssertEqual(Access.restorableSlots(of: b, toCamera: "99999", tier: .subscriber), Array(1 ... 7))
    }

    func testBundleRoundTripMarksBackupsImported() throws {
        let b = backup(serial: "12345")
        let data = try BackupBundle(backups: [b]).encoded()
        let back = try BackupBundle.decode(data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].origin, .imported)
        XCTAssertTrue(back[0].sameSlots(as: b))
    }

    func testSameSlotsIgnoresNotesButNotNames() {
        let a = backup(serial: nil)
        var b = a
        b.slots[2].recipe.notes = "changed"
        XCTAssertTrue(a.sameSlots(as: b))
        b.slots[2].name = "OTHER"
        XCTAssertFalse(a.sameSlots(as: b))
    }

    func testRestorableUsesTheCameraName() {
        let s = CameraBackup.Slot(slot: 3, name: "KODA64", recipe: Recipe(name: "Kodachrome 64"))
        XCTAssertEqual(s.restorable.name, "KODA64")
        XCTAssertEqual(CameraBackup.Slot(slot: 4, name: "", recipe: Recipe()).restorable.name, "C4")
    }
}

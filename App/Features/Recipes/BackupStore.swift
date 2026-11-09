import Foundation
import Observation
import FujiKit

/// Every state of C1–C7 resync has read, newest first. A backup is added whenever a full read
/// differs from the last one, so the slots before a write and the read-back after it are both
/// kept, and any write can be put back.
@MainActor
@Observable
final class BackupStore {
    private(set) var backups: [CameraBackup] = []
    var lastError: String?

    private let url: URL

    init(filename: String = "backups.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        load()
    }

    var latest: CameraBackup? { backups.first }

    func backup(_ id: UUID) -> CameraBackup? { backups.first { $0.id == id } }

    /// Records a read of the camera. Only a full read of all seven slots counts, and only when
    /// it differs from the newest backup of the same camera.
    @discardableResult
    func record(_ presets: [CameraPreset], serial: String?, model: String = "X-T30 II") -> CameraBackup? {
        let full = Set(presets.map(\.slot))
        guard Access.allSlots.allSatisfy({ full.contains($0) }) else { return nil }
        let slots = presets.filter { Access.allSlots.contains($0.slot) }
            .map { CameraBackup.Slot(slot: $0.slot, name: $0.name, recipe: PresetCodec.decode($0)) }
        let b = CameraBackup(cameraSerial: serial, cameraModel: model, slots: slots)
        if let last = backups.first(where: { $0.cameraSerial == serial && $0.origin == .thisApp }), last.sameSlots(as: b) { return nil }
        backups.insert(b, at: 0)
        save()
        AppLog.write(.recipes, "backed up c1–c7" + (serial.map { " of \($0)" } ?? ""))
        return b
    }

    /// Turns the old single "last read" snapshot into the first backup, once.
    func migrate(from snapshot: RecipeStore.CameraSnapshot?) {
        guard backups.isEmpty, let snapshot, snapshot.slots.count == Access.allSlots.count else { return }
        let slots = snapshot.slots.map { CameraBackup.Slot(slot: $0.slot, name: $0.name, recipe: $0.recipe) }
        backups = [CameraBackup(cameraSerial: nil, takenAt: snapshot.readAt, slots: slots)]
        save()
        AppLog.write(.recipes, "kept the last camera read as the first backup")
    }

    /// Adds backups from a file. They count as imported, never as this camera's own.
    func importData(_ data: Data) -> Int {
        do {
            let incoming = try BackupBundle.decode(data).filter { b in !backups.contains { $0.id == b.id } }
            backups.append(contentsOf: incoming)
            backups.sort { $0.takenAt > $1.takenAt }
            if !incoming.isEmpty { save() }
            return incoming.count
        } catch {
            lastError = "that file isn't a resync backup."
            return 0
        }
    }

    func exportData(_ b: CameraBackup) -> Data {
        (try? BackupBundle(backups: [b]).encoded()) ?? Data()
    }

    func delete(_ id: UUID) {
        backups.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        backups = ((try? d.decode([CameraBackup].self, from: data)) ?? []).sorted { $0.takenAt > $1.takenAt }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        do {
            try e.encode(backups).write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "couldn't save the backups: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
extension BackupStore {
    /// UI tests only: one backup of this camera from an hour ago, matching the seeded slots.
    func seedForUITests(from snapshot: RecipeStore.CameraSnapshot?) {
        guard let snapshot else { return }
        var slots = snapshot.slots.map { CameraBackup.Slot(slot: $0.slot, name: $0.name, recipe: $0.recipe) }
        for n in Access.allSlots where !slots.contains(where: { $0.slot == n }) {
            slots.append(CameraBackup.Slot(slot: n, name: "", recipe: Recipe(name: "C\(n)")))
        }
        backups = [CameraBackup(cameraSerial: nil, takenAt: Date().addingTimeInterval(-3600), slots: slots)]
    }
}
#endif

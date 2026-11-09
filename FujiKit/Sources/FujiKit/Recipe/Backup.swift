import Foundation

/// What C1–C7 held at one moment, kept so any write can be undone.
///
/// A backup never changes once it's saved. Over USB it holds the decoded slots; a Bluetooth
/// backup (`backup.dat`, not built yet) would also keep the raw bytes in `rawBlob`, so a later
/// parser can read old backups.
public struct CameraBackup: Codable, Hashable, Identifiable, Sendable {
    public enum Transport: String, Codable, Sendable { case usb, ble }

    /// Why it was taken. Every full read of the camera that differs from the last backup is kept,
    /// so the state before a write and the read-back after it are both there.
    public enum Trigger: String, Codable, Sendable { case read, manual }

    /// Taken by this app from a camera, or opened from a file. Only the first counts as
    /// the user's own camera when deciding what a free user may restore.
    public enum Origin: String, Codable, Sendable { case thisApp, imported }

    public struct Slot: Codable, Hashable, Sendable {
        public var slot: Int
        /// As stored on the camera: short and often upper-case.
        public var name: String
        public var recipe: Recipe

        public init(slot: Int, name: String, recipe: Recipe) {
            self.slot = slot
            self.name = name
            self.recipe = recipe
        }

        /// The recipe to write back: the camera's own name, not the library's.
        public var restorable: Recipe {
            var r = recipe
            r.name = name.isEmpty ? "C\(slot)" : name
            return r
        }
    }

    public var id: UUID
    /// The camera's serial, when the transport reports one.
    public var cameraSerial: String?
    public var cameraModel: String
    public var takenAt: Date
    public var transport: Transport
    public var trigger: Trigger
    public var origin: Origin
    public var slots: [Slot]
    public var rawBlob: Data?
    public var formatVersion: Int

    public static let currentFormat = 1

    public init(id: UUID = UUID(), cameraSerial: String?, cameraModel: String = "X-T30 II", takenAt: Date = Date(),
                transport: Transport = .usb, trigger: Trigger = .read, origin: Origin = .thisApp,
                slots: [Slot], rawBlob: Data? = nil, formatVersion: Int = CameraBackup.currentFormat) {
        self.id = id
        self.cameraSerial = cameraSerial
        self.cameraModel = cameraModel
        self.takenAt = takenAt
        self.transport = transport
        self.trigger = trigger
        self.origin = origin
        self.slots = slots.sorted { $0.slot < $1.slot }
        self.rawBlob = rawBlob
        self.formatVersion = formatVersion
    }

    public func slot(_ n: Int) -> Slot? { slots.first { $0.slot == n } }

    /// Same names and same camera settings in every slot. Notes and timestamps don't count.
    public func sameSlots(as other: CameraBackup) -> Bool {
        guard slots.count == other.slots.count else { return false }
        return zip(slots, other.slots).allSatisfy { a, b in
            a.slot == b.slot && a.name == b.name && a.recipe.settingsKey == b.recipe.settingsKey
        }
    }

    /// From the camera's own name for the file: `resync c1-c7 2026-11-09 0812.json`.
    public var fileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "resync c1-c7 \(f.string(from: takenAt)).json"
    }
}

/// The on-disk file for one or more backups, so an export opens in another copy of resync.
public struct BackupBundle: Codable, Sendable {
    public static let format = "fx-companion.backups"
    public var format: String
    public var version: Int
    public var backups: [CameraBackup]

    public init(backups: [CameraBackup]) {
        self.format = Self.format
        self.version = 1
        self.backups = backups
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// Reads a bundle. Every backup in it is marked imported, whatever the file says, so a
    /// shared file never counts as the reader's own camera.
    public static func decode(_ data: Data) throws -> [CameraBackup] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let bundle = try d.decode(BackupBundle.self, from: data)
        guard bundle.format == format else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a resync backup")) }
        return bundle.backups.map { var b = $0; b.origin = .imported; return b }
    }
}

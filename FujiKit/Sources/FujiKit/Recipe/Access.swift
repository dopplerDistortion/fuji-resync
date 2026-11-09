import Foundation

/// Free or subscribed. Everything else about the subscription lives in the app.
public enum Tier: String, Codable, Sendable {
    case free, subscriber
}

/// What each tier may do to the camera's custom slots. See `docs/recipes-requirements.md` §5.
///
/// The library, reading the camera and backups are free for everyone. The gate is on writing:
/// free users write C1; C2–C7 need a subscription. A free user may still put back their own
/// camera's slots from a backup this app took, because that is an undo, not a new recipe.
public enum Access {
    public static let freeSlots: Set<Int> = [1]
    public static let allSlots = 1 ... 7

    public static func canWrite(slot: Int, tier: Tier) -> Bool {
        guard allSlots.contains(slot) else { return false }
        return tier == .subscriber || freeSlots.contains(slot)
    }

    /// Whether `slot` may be restored from `backup` onto the camera with `serial`.
    ///
    /// - Subscribers: any slot from any backup.
    /// - Free: C1 from any backup; C2–C7 only from a backup this app took of the same camera.
    ///   When neither side knows a serial, a backup this app took counts as the same camera.
    public static func canRestore(slot: Int, from backup: CameraBackup, toCamera serial: String?, tier: Tier) -> Bool {
        if canWrite(slot: slot, tier: tier) { return true }
        guard allSlots.contains(slot), backup.origin == .thisApp else { return false }
        switch (backup.cameraSerial, serial) {
        case let (a?, b?): return a == b
        case (nil, _), (_, nil): return true
        }
    }

    /// The slots of `backup` that may be restored, in order.
    public static func restorableSlots(of backup: CameraBackup, toCamera serial: String?, tier: Tier) -> [Int] {
        backup.slots.map(\.slot).filter { canRestore(slot: $0, from: backup, toCamera: serial, tier: tier) }
    }
}

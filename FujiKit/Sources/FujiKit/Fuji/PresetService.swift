import Foundation

/// Reads and writes the camera's C1–C7 custom settings over an open PTP session.
///
/// The camera must be in USB "RAW CONV. / BACKUP RESTORE" mode (SET UP → CONNECTION SETTING → PC CONNECTION MODE).
public struct PresetService: Sendable {
    public let session: PTPSession
    public let slotCount: Int

    public init(session: PTPSession, slotCount: Int = 7) {
        self.session = session
        self.slotCount = slotCount
    }

    public struct WriteReport: Equatable, Sendable {
        public var slot: Int
        public var written: Int
        public var attempted: Int
        /// Human-readable lines for each rejected property.
        public var rejected: [String]
        public var verified: Bool
        public var ok: Bool { verified && rejected.isEmpty }
    }

    public enum PresetError: Error, Equatable, CustomStringConvertible {
        case unsupported
        case slotSelect(Int, PTPResponseCode)
        case nameWrite(PTPResponseCode)
        case verifyMismatch(code: UInt16)

        public var description: String {
            switch self {
            case .unsupported: return "this connection can't reach custom settings. set the camera to RAW CONV. / BACKUP RESTORE and reconnect."
            case let .slotSelect(s, c): return "camera refused to select C\(s) (\(c))"
            case let .nameWrite(c): return "camera refused the name (\(c))"
            case let .verifyMismatch(code): return String(format: "value 0x%04X read back differently", code)
            }
        }
    }

    public func readSlot(_ slot: Int) async throws -> CameraPreset {
        try await select(slot)
        let name = (try? await session.getString(FujiProp.presetName)) ?? ""
        var raw: [UInt16: Data] = [:]
        for code in FujiProp.presetBlock {
            if let d = try await session.tryGetProp(code) { raw[code] = d }
        }
        return CameraPreset(slot: slot, name: name, raw: raw)
    }

    public func readAll() async throws -> [CameraPreset] {
        let original = try? await session.getU16(FujiProp.presetSlot)
        var out: [CameraPreset] = []
        for slot in 1 ... slotCount {
            out.append(try await readSlot(slot))
        }
        if let original { try? await session.setU16(FujiProp.presetSlot, original) }
        return out
    }

    /// Writes `recipe` into `slot` and reads every accepted value back to verify it.
    public func write(_ recipe: Recipe, to slot: Int, base: CameraPreset? = nil) async throws -> WriteReport {
        let baseRaw: [UInt16: Data]
        if let base, base.slot == slot { baseRaw = base.raw } else { baseRaw = try await readSlot(slot).raw }

        try await select(slot)
        try await Task.sleep(nanoseconds: 100_000_000)

        var w = ByteWriter(); w.ptpString(String(recipe.name.prefix(Recipe.maxNameLength)))
        let nameCode = try await session.trySetProp(FujiProp.presetName, w.data)
        guard nameCode == .ok else { throw PresetError.nameWrite(nameCode) }

        let writes = PresetCodec.encode(recipe, base: baseRaw)
        var accepted: [PropWrite] = []
        var rejected: [String] = []
        for pw in writes {
            let code = try await session.trySetProp(pw.code, pw.value)
            if code == .ok { accepted.append(pw) } else {
                rejected.append(String(format: "0x%04X ← [%@]: %@", pw.code, pw.value.hex, code.description))
            }
        }

        for pw in accepted {
            guard let back = try await session.tryGetProp(pw.code) else { continue }
            if back.count == pw.value.count, back != pw.value {
                throw PresetError.verifyMismatch(code: pw.code)
            }
        }

        return WriteReport(slot: slot, written: accepted.count, attempted: writes.count, rejected: rejected, verified: true)
    }

    private func select(_ slot: Int) async throws {
        var w = ByteWriter(); w.u16(UInt16(slot))
        let code = try await session.trySetProp(FujiProp.presetSlot, w.data)
        if code == .devicePropNotSupported || code == .operationNotSupported { throw PresetError.unsupported }
        guard code == .ok else { throw PresetError.slotSelect(slot, code) }
    }
}

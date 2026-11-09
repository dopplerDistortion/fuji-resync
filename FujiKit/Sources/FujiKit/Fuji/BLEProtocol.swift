import Foundation

/// Fujifilm Bluetooth LE protocol: identifiers and packet encoders.
///
/// From gkoh/furble and petabyt/libfuji (both MIT), which reverse-engineered the
/// FUJIFILM XApp / Camera Remote traffic. The X-T30 II is in the same family as the
/// verified X-T30, X-S10 and X-E4.
public enum FujiBLE {
    /// Bluetooth SIG company ID in the advertisement's manufacturer data.
    public static let companyID: UInt16 = 0x04D8

    public enum Service {
        /// Legacy pairing service.
        public static let pairing = "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8"
        /// Configuration / notifications service (also carries the geotag-request notification).
        public static let configuration = "4C0020FE-F3B6-40DE-ACC9-77D129067B14"
        /// Location service: the phone writes position + time here.
        public static let geotag = "3B46EC2B-48BA-41FD-B1B8-ED860B60D22B"
        /// Shutter service.
        public static let shutter = "6514EB81-4E8F-458D-AA2A-E691336CDFAC"
        /// Advertised by "secure" firmware (circa July 2025 and later).
        public static let secureAdvertised = "A9D2B304-E8D6-4902-8336-352B772D7597"
        public static let securePairing = "123D8F06-62A1-4935-9322-833C531EE225"
        public static let secureNotifications = "4E941240-D01D-46B9-A5EA-67636806830B"
        /// Advertised by legacy firmware.
        public static let cameraRemote = "AF854C2E-B214-458E-97E2-912C4ECF2CB8"
        public static let xapp = "117C4142-EDD4-4C77-8696-DD18EEBB770A"
    }

    public enum Characteristic {
        public static let pairToken = "ABA356EB-9633-4E60-B73F-F52516DBD671"
        public static let clientIdentity = "85B9163E-62D1-49FF-A6F5-054B4630D4A1"
        public static let indication1 = "A68E3F66-0FCC-4395-8D4C-AA980B5877FA"
        public static let indication2 = "BD17BA04-B76B-4892-A545-B73BA1F74DAE"
        public static let notification1 = "F9150137-5D40-4801-A8DC-F7FC5B01DA50"
        public static let indication3 = "049EC406-EF75-4205-A390-08FE209C51F0"
        /// Notifies `01 00` when the camera wants a fresh location.
        public static let geotagRequest = "AD06C7B7-F41A-46F4-A29A-712055319122"
        public static let geotagWrite = "0F36EC14-29E5-411A-A1B6-64EE8383F090"
        public static let shutter = "7FCF49C6-4FF0-4777-A03D-1A79166AF7A8"
        // Secure firmware
        public static let secureStatus = "F557D96B-8284-4667-8793-B971C1DECA2A"
        public static let geotagSyncInterval = "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B"
    }

    public enum PairingKind: Equatable, Sendable {
        /// Legacy: the advert carries a 4-byte token that we echo back to `pairToken`.
        case legacy(token: Data)
        /// Secure: the camera bonds at the link layer; the advert carries a 5-byte serial to recognise it later.
        case secure(serial: Data)
    }

    /// Parses manufacturer data from an advertisement. Returns nil if it isn't a Fujifilm camera.
    ///
    /// Layout: `u16 companyID | u8 type | payload` where legacy type 0x02 carries a 4-byte token
    /// and secure firmware carries a 5-byte serial.
    public static func parseAdvertisement(manufacturerData d: Data, advertisedServices: [String]) -> PairingKind? {
        guard d.count >= 3 else { return nil }
        var r = ByteReader(d)
        guard (try? r.u16()) == companyID, let type = try? r.u8() else { return nil }
        let payload = r.rest()
        let services = Set(advertisedServices.map { $0.uppercased() })
        if services.contains(Service.secureAdvertised) || services.contains(Service.securePairing), payload.count == 5 {
            return .secure(serial: payload)
        }
        if type == 0x02, payload.count == 4 {
            return .legacy(token: payload)
        }
        return payload.count == 5 ? .secure(serial: payload) : nil
    }

    /// Shutter commands: write `command` then `parameter` to the shutter characteristic.
    public enum Shutter {
        public static let command = Data([0x01, 0x00])
        public static let release = Data([0x00, 0x00])
        public static let press = Data([0x02, 0x00])
        public static let halfPress = Data([0x03, 0x00])
    }

    public static let geotagRequested = Data([0x01, 0x00])
    /// Seconds between camera location requests that we ask for on secure firmware.
    public static let geotagSyncIntervalSeconds: UInt16 = 10

    /// Location + time packet written to `geotagWrite` (23 bytes, packed).
    ///
    /// `i32 lat×1e7 | i32 lon×1e7 | i32 altitude m | 4 pad | u16 year | u8 month | u8 day | u8 h | u8 m | u8 s`
    /// Time is UTC, matching GPS time.
    public static func geotagPacket(latitude: Double, longitude: Double, altitude: Double, date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var w = ByteWriter()
        w.i32(Int32((latitude * 10_000_000).rounded()))
        w.i32(Int32((longitude * 10_000_000).rounded()))
        w.i32(Int32(altitude.rounded()))
        w.bytes(Data(count: 4))
        w.u16(UInt16(c.year ?? 2000))
        w.u8(UInt8(c.month ?? 1))
        w.u8(UInt8(c.day ?? 1))
        w.u8(UInt8(c.hour ?? 0))
        w.u8(UInt8(c.minute ?? 0))
        w.u8(UInt8(c.second ?? 0))
        return w.data
    }

    /// The settings backup (XApp's "Backup") over the file service, read only.
    ///
    /// From Th0rgal/fuji-bridge (MIT), which took the constants and the sequence from a decompile of
    /// XApp 2.2.1. Never run on a real X-T30 II before resync's test: treat every step as a guess.
    ///
    /// 1. subscribe to `transactionState` and `state`
    /// 2. write `01 00` to `request` (settings; `02 00` would be IPTC)
    /// 3. `state` notifies `1` when the file is ready, `0` when the camera is busy
    /// 4. write u32 120 to `partialSize`, u32 0 to `transferIndex`
    /// 5. on each `transactionState` 1 or 2, read `partialData`
    /// 6. on `transactionState` 3, read `information`, write `03 00` to `transferResult`; on any error `00 00`
    public enum Backup {
        public static let fileService = "AF854C2E-B214-458E-97E2-912C4ECF2CB8"
        /// In the shutter service.
        public static let request = "F14E7A88-6F57-4872-A69B-B47EF3295C9B"
        /// In the configuration service. `1` transferable, `0` busy.
        public static let state = "11438C83-CFB0-4511-841B-759E0D2321C8"
        public static let transferIndex = "051DD980-DF9D-4472-A2E1-35811DD24EE1"
        public static let partialSize = "7F3400FE-17E7-4B80-8A0E-81B0343C1B49"
        /// `char name[40]` + u32 size, e.g. `backup.dat`, 33,404 bytes.
        public static let information = "C922AC69-9480-4348-8F4B-9EE29BC30D1D"
        /// `u16 seq | u32 len | data`. seq 0xFFFF is the last piece, which ends with a u16 byte sum.
        public static let partialData = "AC0C799A-FA6C-4DF5-BBC5-BB95CCE7E6EA"
        /// 1/2 a piece is ready, 3 done.
        public static let transactionState = "2E27ED9F-5506-41CD-BA48-DAC06669AD95"
        /// `03 00` finish, `00 00` abort.
        public static let transferResult = "68052E8A-FB91-404F-8847-0EB4BE24308C"

        public static let required = [request, state, partialData, transactionState, transferResult]

        public static let settings = Data([0x01, 0x00])
        public static let finish = Data([0x03, 0x00])
        public static let abort = Data([0x00, 0x00])
        /// Bytes per piece; XApp asks for 120.
        public static let pieceSize: UInt32 = 120
        /// Nothing the camera sends should come close; stops a runaway transfer.
        public static let maxBytes = 1 << 20

        public enum Failure: Error, Equatable, CustomStringConvertible {
            case badPiece
            case tooBig
            case checksum(expected: UInt16, got: UInt16)

            public var description: String {
                switch self {
                case .badPiece: return "the camera sent a malformed piece"
                case .tooBig: return "the backup grew past 1 MB"
                case let .checksum(e, g): return String(format: "checksum %04x, expected %04x", g, e)
                }
            }
        }

        /// u16 or u32 little-endian code at the start of a `transactionState` value.
        public static func stateCode(_ v: Data) -> Int? {
            let b = Array(v)
            guard b.count >= 2 else { return b.first.map(Int.init) }
            return Int(b[0]) | Int(b[1]) << 8
        }

        /// Parses `information`: the file name and its size.
        public static func information(_ v: Data) -> (name: String, size: Int)? {
            let b = Array(v)
            guard b.count >= 44 else { return nil }
            let name = String(bytes: b[0 ..< 40].prefix { $0 != 0 }, encoding: .utf8) ?? ""
            let size = Int(b[40]) | Int(b[41]) << 8 | Int(b[42]) << 16 | Int(b[43]) << 24
            return (name, size)
        }

        /// Puts the pieces together and checks the sum at the end.
        public struct Assembler: Sendable {
            public private(set) var data = Data()
            public private(set) var pieces = 0
            /// The sum the camera sent with the last piece, once it has arrived.
            public private(set) var expected: UInt16?
            private var sum: UInt32 = 0

            public init() {}

            public var isComplete: Bool { expected != nil }
            public var computed: UInt16 { UInt16(truncatingIfNeeded: sum) }

            /// Adds one `partialData` value. True when it was the last piece.
            @discardableResult
            public mutating func add(_ piece: Data) throws -> Bool {
                var r = ByteReader(piece)
                guard let seq = try? r.u16(), let len = try? r.u32(), Int(len) <= r.remaining,
                      let body = try? r.bytes(Int(len)) else { throw Failure.badPiece }
                let last = seq == 0xFFFF
                var payload = body
                if last {
                    guard payload.count >= 2 else { throw Failure.badPiece }
                    let tail = Array(payload.suffix(2))
                    expected = UInt16(tail[0]) | UInt16(tail[1]) << 8
                    payload = payload.dropLast(2)
                }
                guard data.count + payload.count <= Backup.maxBytes else { throw Failure.tooBig }
                data.append(payload)
                sum = payload.reduce(sum) { $0 &+ UInt32($1) }
                pieces += 1
                return last
            }

            /// Throws when the camera's sum doesn't match. No sum (no last piece) passes, as fuji-bridge does.
            public func verify() throws {
                if let expected, expected != computed { throw Failure.checksum(expected: expected, got: computed) }
            }

            /// The file, trimmed to the size the camera reported when that is shorter.
            public func file(size: Int?) -> Data {
                guard let size, size > 0, size < data.count else { return data }
                return data.prefix(size)
            }
        }
    }

    /// Reply to the secure-firmware status read: echo the first three bytes and set the last to 0x20.
    public static func secureStatusAck(_ status: Data) -> Data? {
        guard status.count == 4 else { return nil }
        let s = Array(status)
        return Data([s[0], s[1], s[2], 0x20])
    }
}

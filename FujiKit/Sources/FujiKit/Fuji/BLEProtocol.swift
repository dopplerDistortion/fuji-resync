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

    /// Reply to the secure-firmware status read: echo the first three bytes and set the last to 0x20.
    public static func secureStatusAck(_ status: Data) -> Data? {
        guard status.count == 4 else { return nil }
        let s = Array(status)
        return Data([s[0], s[1], s[2], 0x20])
    }
}

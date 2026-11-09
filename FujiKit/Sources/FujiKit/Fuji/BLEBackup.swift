import Foundation

/// Read-only download of the camera's settings backup (`backup.dat`) over Bluetooth LE.
///
/// The sequence is XApp's BTCameraModel as decompiled and written up by Th0rgal/fuji-bridge (MIT),
/// which only ran it against a fake camera. This is experiment T1 in docs/recipes-requirements.md:
/// nothing here writes camera settings, only the request and the transfer control values.
///
/// 1. listen to FILE_TRANSACTION_STATE and BACKUP_STATE, write BACKUP_REQUEST = `01 00`
/// 2. wait for BACKUP_STATE = 1 (0 means busy)
/// 3. write FILE_PARTIAL_SIZE = 120, FILE_TRANSFER_INDEX = 0
/// 4. on each TRANSACTION_STATE 1 or 2, read FILE_PARTIAL_DATA: `u16 seq | u32 len | data`.
///    seq 0xFFFF is the last piece; its data ends with a u16 sum of every data byte
/// 5. on TRANSACTION_STATE 3, check the sum, read FILE_INFORMATION (name in bytes 0–39, u32 size
///    at 40), write FILE_TRANSFER_RESULT = 3. On any error write 0.
public enum FujiBLEBackup {
    public enum Characteristic {
        /// In the shutter service (6514EB81).
        public static let backupRequest = "F14E7A88-6F57-4872-A69B-B47EF3295C9B"
        /// In the configuration service (4C0020FE).
        public static let backupState = "11438C83-CFB0-4511-841B-759E0D2321C8"
        // File service (AF854C2E).
        public static let fileIndex = "051DD980-DF9D-4472-A2E1-35811DD24EE1"
        public static let filePartialSize = "7F3400FE-17E7-4B80-8A0E-81B0343C1B49"
        public static let fileInformation = "C922AC69-9480-4348-8F4B-9EE29BC30D1D"
        public static let filePartialData = "AC0C799A-FA6C-4DF5-BBC5-BB95CCE7E6EA"
        public static let fileTransactionState = "2E27ED9F-5506-41CD-BA48-DAC06669AD95"
        public static let fileTransferResult = "68052E8A-FB91-404F-8847-0EB4BE24308C"

        public static let required: [String] = [backupRequest, backupState, filePartialData, fileTransactionState]
        public static let all: Set<String> = [backupRequest, backupState, fileIndex, filePartialSize,
                                              fileInformation, filePartialData, fileTransactionState, fileTransferResult]
    }

    public enum Action: Equatable, Sendable {
        case subscribe(String)
        case write(String, Data)
        case read(String)
        case finished(Result)
        case failed(String)
    }

    public struct Result: Equatable, Sendable {
        public var name: String
        public var data: Data
        /// nil when the camera sent no checksum.
        public var checksum: UInt16?
        /// Size the camera reported in FILE_INFORMATION, if it sent one.
        public var reportedSize: Int?
    }

    /// One piece of FILE_PARTIAL_DATA.
    public static func parseChunk(_ chunk: Data) -> (last: Bool, payload: Data)? {
        var r = ByteReader(chunk)
        guard let seq = try? r.u16(), let len = try? r.u32(), Int(len) <= r.remaining,
              let payload = try? r.bytes(Int(len)) else { return nil }
        return (seq == 0xFFFF, payload)
    }

    /// FILE_INFORMATION: a NUL-padded name in bytes 0–39 and a u32 size at 40.
    public static func parseInformation(_ info: Data) -> (name: String?, size: Int?) {
        let b = Array(info)
        let raw = b.prefix(40).prefix { $0 != 0 }
        let name = String(bytes: raw, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        guard b.count >= 44 else { return (name, nil) }
        let size = Int(b[40]) | Int(b[41]) << 8 | Int(b[42]) << 16 | Int(b[43]) << 24
        return (name, size)
    }

    /// The download as a state machine: feed it what the camera sends, do what it returns.
    /// It holds no CoreBluetooth objects, so it can be tested without a camera.
    public struct Download: Sendable {
        public enum Phase: Equatable, Sendable { case idle, waitingReady, transferring, finishing, done, failed }

        public private(set) var phase: Phase = .idle
        public private(set) var data = Data()
        public private(set) var chunks = 0
        private var sum = 0
        private var expected: UInt16?
        private var hasInformation = false

        public init() {}

        public var received: Int { data.count }

        /// `available` is every characteristic UUID the camera offers, upper-case.
        public mutating func start(available: Set<String>) -> [Action] {
            let C = Characteristic.self
            let missing = C.required.filter { !available.contains($0) }
            guard missing.isEmpty else {
                phase = .failed
                return [.failed("this camera has no bluetooth backup service (missing \(missing.map { String($0.prefix(8)) }.joined(separator: ", ")))")]
            }
            hasInformation = available.contains(C.fileInformation)
            phase = .waitingReady
            return [.subscribe(C.fileTransactionState), .subscribe(C.backupState), .write(C.backupRequest, Data([0x01, 0x00]))]
        }

        /// Feed every value the camera sends or answers on a backup characteristic.
        public mutating func receive(_ value: Data, from characteristic: String) -> [Action] {
            let C = Characteristic.self
            switch (phase, characteristic) {
            case (.waitingReady, C.backupState):
                guard let ready = value.first else { return [] }
                guard ready == 1 else { return fail("the camera is busy (backup state \(ready)). leave its menus and try again.") }
                phase = .transferring
                return [.write(C.filePartialSize, Data([120, 0, 0, 0])), .write(C.fileIndex, Data([0, 0, 0, 0]))]

            case (.transferring, C.fileTransactionState):
                guard value.count >= 1 else { return [] }
                var r = ByteReader(value)
                let code = value.count >= 2 ? Int((try? r.u16()) ?? 0) : Int(value[value.startIndex])
                switch code {
                case 1, 2: return [.read(C.filePartialData)]
                case 3:
                    if let expected, expected != UInt16(sum & 0xFFFF) {
                        return fail(String(format: "the backup arrived damaged (sum %04x, camera said %04x)", sum & 0xFFFF, expected))
                    }
                    phase = .finishing
                    return hasInformation ? [.read(C.fileInformation)] : finish(name: nil, size: nil)
                default:
                    return fail("the camera ended the transfer (state \(code))")
                }

            case (.transferring, C.filePartialData):
                guard let part = parseChunk(value) else { return fail("the camera sent a malformed piece: \(value.prefix(16).hex)") }
                chunks += 1
                var body = part.payload
                if part.last, body.count >= 2 {
                    let tail = Array(body.suffix(2))
                    expected = UInt16(tail[0]) | UInt16(tail[1]) << 8
                    body = body.dropLast(2)
                }
                data.append(body)
                sum += body.reduce(0) { $0 + Int($1) }
                return []

            case (.finishing, C.fileInformation):
                let info = parseInformation(value)
                return finish(name: info.name, size: info.size)

            default:
                return []
            }
        }

        /// Call when the camera stays quiet too long.
        public mutating func timedOut() -> [Action] {
            switch phase {
            case .waitingReady: return fail("the camera didn't say the backup is ready")
            case .transferring: return fail("the camera stopped sending after \(data.count) bytes")
            case .finishing: return finish(name: nil, size: nil)
            default: return []
            }
        }

        private mutating func finish(name: String?, size: Int?) -> [Action] {
            if let size, size > 0, size < data.count { data = data.prefix(size) }
            phase = .done
            let result = Result(name: name ?? "backup.dat", data: data, checksum: expected, reportedSize: size)
            return [.write(Characteristic.fileTransferResult, Data([3, 0])), .finished(result)]
        }

        private mutating func fail(_ why: String) -> [Action] {
            phase = .failed
            return [.write(Characteristic.fileTransferResult, Data([0, 0])), .failed(why)]
        }
    }
}

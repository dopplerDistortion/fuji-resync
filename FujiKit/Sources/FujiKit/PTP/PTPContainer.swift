import Foundation

/// A PTP USB-style container: `u32 length | u16 type | u16 code | u32 transactionID | payload`.
///
/// Fujifilm uses this exact framing over USB *and* over its Wi-Fi TCP sockets
/// (libpict calls it `PTP_IP_USB`), so one codec serves both transports.
public struct PTPContainer: Equatable, Sendable {
    public static let headerSize = 12

    public var type: PTPContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: Data

    public init(type: PTPContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    public static func command(_ op: UInt16, transactionID: UInt32, params: [UInt32] = []) -> PTPContainer {
        precondition(params.count <= 5, "PTP allows at most 5 parameters")
        var w = ByteWriter()
        params.forEach { w.u32($0) }
        return PTPContainer(type: .command, code: op, transactionID: transactionID, payload: w.data)
    }

    public var params: [UInt32] {
        var r = ByteReader(payload)
        var out: [UInt32] = []
        while r.remaining >= 4, let v = try? r.u32() { out.append(v) }
        return out
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u32(UInt32(Self.headerSize + payload.count))
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        w.bytes(payload)
        return w.data
    }

    public enum DecodeError: Error, Equatable {
        case truncated
        case badLength(UInt32)
        case unknownType(UInt16)
    }

    /// Decodes one container from the front of `data`. Returns nil if more bytes are needed.
    public static func decode(prefixOf data: Data) throws -> (container: PTPContainer, consumed: Int)? {
        guard data.count >= headerSize else { return nil }
        var r = ByteReader(data)
        let length = try r.u32()
        guard length >= UInt32(headerSize) else { throw DecodeError.badLength(length) }
        guard data.count >= Int(length) else { return nil }
        let rawType = try r.u16()
        guard let type = PTPContainerType(rawValue: rawType) else { throw DecodeError.unknownType(rawType) }
        let code = try r.u16()
        let tid = try r.u32()
        let payload = try r.bytes(Int(length) - headerSize)
        return (PTPContainer(type: type, code: code, transactionID: tid, payload: payload), Int(length))
    }
}

public struct PTPCommand: Sendable, Equatable {
    public var operation: UInt16
    public var params: [UInt32]

    public init(_ operation: UInt16, _ params: [UInt32] = []) {
        self.operation = operation
        self.params = params
    }

    public init(_ operation: PTPOperation, _ params: [UInt32] = []) {
        self.init(operation.rawValue, params)
    }
}

public struct PTPResult: Sendable, Equatable {
    public var code: PTPResponseCode
    public var params: [UInt32]
    public var data: Data

    public init(code: PTPResponseCode, params: [UInt32] = [], data: Data = Data()) {
        self.code = code
        self.params = params
        self.data = data
    }
}

public enum PTPError: Error, Equatable, CustomStringConvertible {
    case response(op: UInt16, code: PTPResponseCode)
    case protocolViolation(String)
    case disconnected
    case timeout

    public var description: String {
        switch self {
        case let .response(op, code): return String(format: "op 0x%04X: %@", op, code.description)
        case let .protocolViolation(s): return "protocol: \(s)"
        case .disconnected: return "camera disconnected"
        case .timeout: return "camera did not answer in time"
        }
    }
}

/// Anything that can run one PTP transaction (command, optional data-out phase, data-in, response).
public protocol PTPTransport: AnyObject, Sendable {
    func execute(_ command: PTPCommand, dataOut: Data?) async throws -> PTPResult
}

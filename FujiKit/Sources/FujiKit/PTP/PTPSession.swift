import Foundation

/// Convenience calls on top of a transport. Serialises access so callers can't interleave transactions.
public actor PTPSession {
    public let transport: PTPTransport
    /// Receives one line per transaction (op, params, payload, response) for debugging.
    public let trace: (@Sendable (String) -> Void)?

    public init(transport: PTPTransport, trace: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.trace = trace
    }

    /// Every transaction goes through here so it can be traced.
    public func exec(_ command: PTPCommand, dataOut: Data? = nil) async throws -> PTPResult {
        do {
            let r = try await transport.execute(command, dataOut: dataOut)
            if let trace {
                var line = String(format: "ptp 0x%04X", command.operation)
                if !command.params.isEmpty { line += " [" + command.params.map { String(format: "0x%X", $0) }.joined(separator: ",") + "]" }
                if let dataOut { line += " → " + dataOut.prefix(32).hex }
                line += " ⇒ \(r.code)"
                if !r.data.isEmpty { line += " ← \(r.data.count)b " + r.data.prefix(32).hex }
                trace(line)
            }
            return r
        } catch {
            trace?(String(format: "ptp 0x%04X failed: ", command.operation) + String(describing: error))
            throw error
        }
    }

    @discardableResult
    public func run(_ command: PTPCommand, dataOut: Data? = nil, allow: Set<PTPResponseCode> = [.ok]) async throws -> PTPResult {
        let result = try await exec(command, dataOut: dataOut)
        guard allow.contains(result.code) else {
            throw PTPError.response(op: command.operation, code: result.code)
        }
        return result
    }

    public func openSession(id: UInt32 = 1) async throws {
        try await run(PTPCommand(.openSession, [id]), allow: [.ok, .sessionAlreadyOpen])
    }

    public func closeSession() async throws {
        try await run(PTPCommand(.closeSession))
    }

    // MARK: Device properties

    public func getProp(_ code: UInt16) async throws -> Data {
        try await run(PTPCommand(.getDevicePropValue, [UInt32(code)])).data
    }

    /// Returns nil instead of throwing when the camera rejects the property.
    public func tryGetProp(_ code: UInt16) async throws -> Data? {
        let r = try await exec(PTPCommand(.getDevicePropValue, [UInt32(code)]))
        return r.code == .ok ? r.data : nil
    }

    public func setProp(_ code: UInt16, _ value: Data) async throws {
        try await run(PTPCommand(.setDevicePropValue, [UInt32(code)]), dataOut: value)
    }

    /// Returns the response code instead of throwing, for best-effort writes.
    public func trySetProp(_ code: UInt16, _ value: Data) async throws -> PTPResponseCode {
        try await exec(PTPCommand(.setDevicePropValue, [UInt32(code)]), dataOut: value).code
    }

    public func getU16(_ code: UInt16) async throws -> UInt16 {
        var r = ByteReader(try await getProp(code)); return try r.u16()
    }

    public func getU32(_ code: UInt16) async throws -> UInt32 {
        let d = try await getProp(code)
        var r = ByteReader(d)
        return d.count >= 4 ? try r.u32() : UInt32(try r.u16())
    }

    public func setU16(_ code: UInt16, _ v: UInt16) async throws {
        var w = ByteWriter(); w.u16(v); try await setProp(code, w.data)
    }

    public func setU32(_ code: UInt16, _ v: UInt32) async throws {
        var w = ByteWriter(); w.u32(v); try await setProp(code, w.data)
    }

    public func getString(_ code: UInt16) async throws -> String {
        var r = ByteReader(try await getProp(code)); return try r.ptpString()
    }

    public func setString(_ code: UInt16, _ s: String) async throws {
        var w = ByteWriter(); w.ptpString(s); try await setProp(code, w.data)
    }
}

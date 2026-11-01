import Foundation

/// A reliable ordered byte stream (a TCP socket in the app, an in-memory pipe in tests).
public protocol ByteStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// Returns exactly `count` bytes or throws.
    func receive(exactly count: Int) async throws -> Data
}

extension ByteStream {
    public func receiveContainer() async throws -> PTPContainer {
        let head = try await receive(exactly: 4)
        var r = ByteReader(head)
        let length = Int(try r.u32())
        guard length >= PTPContainer.headerSize, length < 64 << 20 else {
            throw PTPContainer.DecodeError.badLength(UInt32(length))
        }
        let body = try await receive(exactly: length - 4)
        guard let (c, _) = try PTPContainer.decode(prefixOf: head + body) else {
            throw PTPContainer.DecodeError.truncated
        }
        return c
    }
}

/// Runs PTP transactions over a byte stream using USB-style containers (Fujifilm's Wi-Fi framing).
public actor StreamPTPTransport: PTPTransport {
    private let stream: ByteStream
    private var nextTransaction: UInt32

    public init(stream: ByteStream, firstTransactionID: UInt32 = 1) {
        self.stream = stream
        self.nextTransaction = firstTransactionID
    }

    public nonisolated func execute(_ command: PTPCommand, dataOut: Data?) async throws -> PTPResult {
        try await run(command, dataOut: dataOut)
    }

    private func run(_ command: PTPCommand, dataOut: Data?) async throws -> PTPResult {
        let tid = nextTransaction
        nextTransaction &+= 1

        var out = PTPContainer.command(command.operation, transactionID: tid, params: command.params).encoded()
        if let dataOut {
            out += PTPContainer(type: .data, code: command.operation, transactionID: tid, payload: dataOut).encoded()
        }
        try await stream.send(out)

        var dataIn = Data()
        while true {
            let c = try await stream.receiveContainer()
            switch c.type {
            case .data:
                dataIn.append(c.payload)
            case .response:
                return PTPResult(code: PTPResponseCode(rawValue: c.code), params: c.params, data: dataIn)
            case .event, .command:
                // Events normally arrive on their own socket; ignore strays on the command channel.
                continue
            }
        }
    }
}

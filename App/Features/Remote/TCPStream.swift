import Foundation
import Network
import FujiKit

/// `ByteStream` over a Network.framework TCP connection.
final class TCPStream: ByteStream, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue

    init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi // the camera's AP has no internet; don't let iOS route around it
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        queue = DispatchQueue(label: "resync.tcp.\(port)")
    }

    func open(timeout: TimeInterval = 6) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case let .failed(e): once.run { cont.resume(throwing: e) }
                case let .waiting(e):
                    // .waiting usually means no route: phone isn't on the camera's Wi-Fi.
                    once.run { cont.resume(throwing: e) }
                case .cancelled: once.run { cont.resume(throwing: PTPError.disconnected) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.run { cont.resume(throwing: PTPError.timeout) } }
        }
    }

    func close() { connection.cancel() }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - out.count) { data, _, done, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    cont.resume(throwing: done ? PTPError.disconnected : PTPError.protocolViolation("empty read"))
                }
            }
            out.append(chunk)
        }
        return out
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

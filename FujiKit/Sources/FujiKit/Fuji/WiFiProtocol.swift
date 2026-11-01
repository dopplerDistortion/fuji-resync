import Foundation

/// Fujifilm "Wireless communication" mode over the camera's own Wi-Fi access point.
///
/// Three TCP sockets to 192.168.0.1: commands on 55740, events on 55741, live view JPEGs on 55742.
/// Every message on the command socket is a USB-style PTP container (see `PTPContainer`),
/// except the very first init packet. Sequence from petabyt/libfuji (MIT).
public enum FujiWiFi {
    public static let host = "192.168.0.1"
    public static let commandPort: UInt16 = 55740
    public static let eventPort: UInt16 = 55741
    public static let liveViewPort: UInt16 = 55742

    public static let protocolVersion: UInt32 = 0x8F53_E4F2
    /// Remote-mode version Fujifilm's own app announces.
    public static let remoteVersion: UInt32 = 0x0002_000C

    public enum CameraState: UInt16, Sendable {
        case waitingForAccess = 0
        case multipleTransfer = 1
        case fullAccess = 2
        case pcAutoSave = 3
        case remoteAccess = 6
    }

    public enum ClientState: UInt16, Sendable {
        case viewAllImages = 2
        case remote = 5
    }

    /// The 82-byte init packet: `u32 len | u32 type=1 | u32 version | 16-byte GUID | 54-byte UTF-16LE name`.
    public static func initPacket(clientName: String) -> Data {
        var w = ByteWriter()
        w.u32(0x52)
        w.u32(1)
        w.u32(protocolVersion)
        w.u32(0x5D48_A5AD); w.u32(0x0B7F_B287); w.u32(0xD0DE_D5D3); w.u32(0)
        var name = Data(count: 54)
        for (i, unit) in clientName.utf16.prefix(26).enumerated() {
            name[i * 2] = UInt8(unit & 0xFF)
            name[i * 2 + 1] = UInt8(unit >> 8)
        }
        w.bytes(name)
        return w.data
    }

    public struct InitResponse: Sendable, Equatable {
        public var accepted: Bool
        public var cameraName: String
    }

    /// Parses the camera's reply to the init packet. Type 5 means it refused (usually: not paired / pressed cancel).
    public static func parseInitResponse(_ d: Data) -> InitResponse {
        var r = ByteReader(d)
        _ = try? r.u32()
        let type = (try? r.u32()) ?? 0
        guard type != 5 else { return InitResponse(accepted: false, cameraName: "") }
        // u32 x1..x4 then a UTF-16LE name
        _ = try? r.bytes(16)
        var units: [UInt16] = []
        while r.remaining >= 2, let u = try? r.u16(), u != 0 { units.append(u) }
        return InitResponse(accepted: true, cameraName: String(decoding: units, as: UTF16.self))
    }

    /// One entry from the events-list property (0xD212): `u16 count | (u16 code, u32 value)*`.
    public static func parseEvents(_ d: Data) -> [UInt16: UInt32] {
        var r = ByteReader(d)
        guard let n = try? r.u16() else { return [:] }
        var out: [UInt16: UInt32] = [:]
        for _ in 0 ..< n {
            guard let code = try? r.u16(), let value = try? r.u32() else { break }
            out[code] = value
        }
        return out
    }

    /// Live-view frames on port 55742: an 18-byte header whose first u32 is the total length
    /// (header included), followed by a JPEG.
    public static let liveViewHeaderSize = 18

    public static func liveViewFrameLength(header: Data) -> Int? {
        guard header.count >= 4 else { return nil }
        var r = ByteReader(header)
        guard let total = try? r.u32(), total > UInt32(liveViewHeaderSize), total < 8 << 20 else { return nil }
        return Int(total) - liveViewHeaderSize
    }
}

/// Drives the Wi-Fi remote handshake and capture over three streams.
public actor FujiRemoteSession {
    public let session: PTPSession
    private let command: ByteStream
    public private(set) var cameraName = ""
    public private(set) var cameraState: FujiWiFi.CameraState?
    private var openCaptureActive = false

    public enum RemoteError: Error, CustomStringConvertible, Equatable {
        case refused
        case notRemoteCapable

        public var description: String {
            switch self {
            case .refused: return "camera refused the connection. press OK on the camera when it asks, then try again."
            case .notRemoteCapable: return "camera is not in remote mode. pick 'wireless communication' on the camera."
            }
        }
    }

    /// - Parameter command: the 55740 stream, before anything has been sent on it.
    public init(command: ByteStream, trace: (@Sendable (String) -> Void)? = nil) {
        self.command = command
        self.session = PTPSession(transport: StreamPTPTransport(stream: command, firstTransactionID: 1), trace: trace)
    }

    /// Runs the handshake. `onStatus` receives short human-readable progress lines.
    /// Returns once the camera grants remote access; the caller then opens the event and live-view sockets.
    public func connect(clientName: String, onStatus: @Sendable (String) -> Void = { _ in }) async throws {
        onStatus("hello")
        try await command.send(FujiWiFi.initPacket(clientName: clientName))
        let head = try await command.receive(exactly: 8)
        var hr = ByteReader(head)
        let len = Int(try hr.u32())
        let rest = len > 8 ? try await command.receive(exactly: len - 8) : Data()
        let resp = FujiWiFi.parseInitResponse(head + rest)
        guard resp.accepted else { throw RemoteError.refused }
        cameraName = resp.cameraName

        try await Task.sleep(nanoseconds: 60_000_000) // camera needs ≥50 ms before OpenSession
        onStatus("open session")
        try await session.openSession(id: 1)

        onStatus("waiting for OK on camera")
        try await pollState(until: { $0 != .waitingForAccess })

        // Announce versions the way Fujifilm's app does.
        _ = try? await session.tryGetProp(FujiProp.getObjectVersion)
        _ = try? await session.tryGetProp(FujiProp.remoteGetObjectVersion)
        _ = try? await session.tryGetProp(FujiProp.imageGetVersion)
        let remoteVersion = try? await session.tryGetProp(FujiProp.remoteVersion)

        guard remoteVersion != nil || cameraState == .remoteAccess else { throw RemoteError.notRemoteCapable }

        onStatus("remote mode")
        var w = ByteWriter(); w.u16(FujiWiFi.ClientState.remote.rawValue)
        _ = try await session.trySetProp(FujiProp.clientState, w.data)
        try await refreshEvents()
        var v = ByteWriter(); v.u32(FujiWiFi.remoteVersion)
        _ = try await session.trySetProp(FujiProp.remoteVersion, v.data)
    }

    /// Opens remote capture. After this succeeds the camera accepts connections on the event and live-view ports.
    public func startLiveView() async throws {
        guard !openCaptureActive else { return }
        try await session.run(PTPCommand(.initiateOpenCapture, [0, 0]))
        openCaptureActive = true
        try await refreshEvents()
    }

    public func stopLiveView() async throws {
        guard openCaptureActive else { return }
        openCaptureActive = false
        _ = try await session.exec(PTPCommand(.terminateOpenCapture, [0]))
    }

    /// Takes a picture with the current camera settings.
    public func capture() async throws {
        try await session.run(PTPCommand(.initiateCapture, [0, 0]))
    }

    public func refreshEvents() async throws {
        guard let d = try await session.tryGetProp(FujiProp.eventsList) else { return }
        let events = FujiWiFi.parseEvents(d)
        if let s = events[FujiProp.cameraState] { cameraState = FujiWiFi.CameraState(rawValue: UInt16(truncatingIfNeeded: s)) }
    }

    public func disconnect() async {
        try? await stopLiveView()
        _ = try? await session.exec(PTPCommand(.closeSession))
    }

    private func pollState(until done: (FujiWiFi.CameraState?) -> Bool, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await refreshEvents()
        while !done(cameraState) {
            if Date() > deadline { throw PTPError.timeout }
            try await Task.sleep(nanoseconds: 150_000_000)
            try await refreshEvents()
        }
    }
}

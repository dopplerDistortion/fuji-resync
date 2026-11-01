import Foundation
import Network
import NetworkExtension
import Observation
import UIKit
import FujiKit

/// Remote shutter and live view over the camera's Wi-Fi access point.
@MainActor
@Observable
final class WiFiRemoteController {
    enum Phase: Equatable {
        case idle
        case joining
        case connecting(String)
        case live(String)
        case fault(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var frame: UIImage?
    private(set) var fps: Double = 0
    private(set) var cameraName = ""
    private(set) var capturing = false
    private(set) var log: [String] = []

    @ObservationIgnored private var command: TCPStream?
    @ObservationIgnored private var events: TCPStream?
    @ObservationIgnored private var video: TCPStream?
    @ObservationIgnored private var remote: FujiRemoteSession?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Set while we tear down on purpose, so socket errors aren't reported as faults.
    @ObservationIgnored private var stopping = false

    var isLive: Bool { if case .live = phase { return true } else { return false } }

    /// Runs the handshake. With `joinNetwork` (needs the Hotspot entitlement, paid accounts only)
    /// it first asks iOS to join any network starting with "FUJIFILM-".
    func connect(joinNetwork: Bool = false) async {
        await shutdown()
        if joinNetwork {
            phase = .joining
            note("joining FUJIFILM-… wi-fi")
            let config = NEHotspotConfiguration(ssidPrefix: "FUJIFILM-")
            config.joinOnce = true
            do {
                try await NEHotspotConfigurationManager.shared.apply(config)
            } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain
                && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                // already on it
            } catch {
                note("couldn't join automatically: \(error.localizedDescription)")
                // Fall through: the user may have joined in Settings.
            }
        }

        phase = .connecting("camera")
        do {
            let cmd = TCPStream(host: FujiWiFi.host, port: FujiWiFi.commandPort)
            try await cmd.open()
            command = cmd
            let session = FujiRemoteSession(command: cmd, trace: { AppLog.write(.wifi, $0) })
            remote = session
            try await session.connect(clientName: "resync") { [weak self] s in
                Task { @MainActor in self?.note(s) }
            }
            cameraName = await session.cameraName
            try await session.startLiveView()
            try await openSideChannels()
            phase = .live(cameraName.isEmpty ? "camera" : cameraName)
            note("live")
        } catch {
            fail(Self.explain(error))
        }
    }

    /// Plain-language fault copy: the problem, then the next step.
    static func explain(_ error: Error) -> String {
        if let nw = error as? NWError, case let .posix(code) = nw {
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT:
                return "the phone isn't on the camera's wi-fi. open settings → wi-fi, join FUJIFILM-…, then connect again."
            case .ECONNREFUSED:
                return "the camera refused the connection. on the camera, open wireless communication again, then connect."
            default: break
            }
        }
        if let p = error as? PTPError, p == .timeout {
            return "the camera didn't answer. check it shows the wireless communication screen, then connect again."
        }
        if let r = error as? FujiRemoteSession.RemoteError { return r.description }
        return "\(error). on the camera, open wireless communication and check the phone is on its FUJIFILM-… network."
    }

    func shutter() async {
        guard let remote, !capturing else { return }
        capturing = true
        defer { capturing = false }
        do {
            try await remote.capture()
            note("captured")
        } catch {
            note("shutter failed: \(error)")
        }
    }

    func disconnect() {
        Task { await shutdown() }
    }

    /// Ends remote mode cleanly: stop the reader loops, tell the camera we're leaving, then close sockets.
    private func shutdown() async {
        stopping = true
        defer { stopping = false }
        tasks.forEach { $0.cancel() }
        tasks = []
        if let remote {
            note("disconnecting")
            // Say goodbye, but don't hang if the camera is already gone.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await remote.disconnect() }
                group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        [video, events, command].forEach { $0?.close() }
        video = nil; events = nil; command = nil; remote = nil
        frame = nil
        if phase != .idle { phase = .idle }
    }

    private func openSideChannels() async throws {
        // The camera expects the event socket to be open before streaming.
        let ev = TCPStream(host: FujiWiFi.host, port: FujiWiFi.eventPort)
        try await ev.open()
        events = ev
        tasks.append(Task.detached { [ev] in
            while !Task.isCancelled {
                guard (try? await ev.receiveContainer()) != nil else { break }
            }
        })

        let lv = TCPStream(host: FujiWiFi.host, port: FujiWiFi.liveViewPort)
        try await lv.open()
        video = lv
        tasks.append(Task.detached { [weak self, lv] in
            var count = 0
            var windowStart = Date()
            while !Task.isCancelled {
                do {
                    let header = try await lv.receive(exactly: FujiWiFi.liveViewHeaderSize)
                    guard let len = FujiWiFi.liveViewFrameLength(header: header) else { continue }
                    let jpeg = try await lv.receive(exactly: len)
                    guard let image = UIImage(data: jpeg) else { continue }
                    count += 1
                    let elapsed = Date().timeIntervalSince(windowStart)
                    let rate: Double? = elapsed >= 1 ? Double(count) / elapsed : nil
                    if elapsed >= 1 { count = 0; windowStart = Date() }
                    await MainActor.run {
                        self?.frame = image
                        if let rate { self?.fps = rate }
                    }
                } catch {
                    await MainActor.run {
                        guard let self, !self.stopping, !Task.isCancelled else { return }
                        self.fail("live view stopped: \(error). move closer to the camera and connect again.")
                    }
                    break
                }
            }
        })
    }

    private func fail(_ msg: String) {
        guard !stopping else { return }
        note("fault: \(msg)")
        tasks.forEach { $0.cancel() }
        phase = .fault(msg)
    }

    private func note(_ s: String) {
        AppLog.write(.wifi, s)
        log.append(s)
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
}

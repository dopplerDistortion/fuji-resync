import Foundation
import ImageCaptureCore
import Observation
import FujiKit

/// PTP pass-through over USB using ImageCaptureCore (iOS 13+). The framework owns the session;
/// we only send raw command containers.
final class ICCPTPTransport: PTPTransport, @unchecked Sendable {
    private let camera: ICCameraDevice
    private let lock = NSLock()
    private var nextTID: UInt32 = 1

    init(camera: ICCameraDevice) { self.camera = camera }

    func execute(_ command: PTPCommand, dataOut: Data?) async throws -> PTPResult {
        lock.lock(); let tid = nextTID; nextTID &+= 1; lock.unlock()
        let container = PTPContainer.command(command.operation, transactionID: tid, params: command.params).encoded()
        // ImageCaptureCore wants the bare payload for the data-out phase.
        return try await withCheckedThrowingContinuation { cont in
            camera.requestSendPTPCommand(container, outData: dataOut) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let (resp, _) = try? PTPContainer.decode(prefixOf: response), resp.type == .response else {
                    cont.resume(throwing: PTPError.protocolViolation("no response container (\(response.count) bytes)"))
                    return
                }
                // Some iOS versions hand back the data phase with its container header; strip it if so.
                var payload = data
                if let (dc, used) = try? PTPContainer.decode(prefixOf: data), dc.type == .data, used == data.count {
                    payload = dc.payload
                }
                cont.resume(returning: PTPResult(code: PTPResponseCode(rawValue: resp.code), params: resp.params, data: payload))
            }
        }
    }
}

/// Finds the camera on the USB-C port and exposes the C1–C7 preset service.
@MainActor
@Observable
final class USBCameraController: NSObject {
    enum Phase: Equatable {
        case idle
        case needsPermission
        case searching
        case opening(String)
        case ready(String)
        case fault(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var slots: [CameraPreset] = []
    private(set) var busy: String?
    private(set) var log: [String] = []

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var camera: ICCameraDevice?
    @ObservationIgnored private var service: PresetService?

    var isReady: Bool { if case .ready = phase { return true } else { return false } }

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard phase == .idle || phase == .needsPermission || { if case .fault = phase { return true }; return false }() else { return }
        browser.requestControlAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if status == .authorized {
                    self.phase = .searching
                    if !self.browser.isBrowsing { self.browser.start() }
                } else {
                    self.phase = .needsPermission
                }
            }
        }
    }

    func stop() {
        browser.stop()
        camera?.requestCloseSession()
        camera = nil
        service = nil
        slots = []
        phase = .idle
    }

    func refreshSlots() async {
        guard let service else { return }
        busy = "reading c1–c7"
        defer { busy = nil }
        do {
            slots = try await service.readAll()
            note("read \(slots.count) custom settings")
        } catch {
            fail(error)
        }
    }

    /// Reads C1–C7 fresh and hands them to `save`. One action from camera to library.
    func pull(into store: RecipeStore) async -> (added: Int, already: Int)? {
        guard service != nil else { return nil }
        await refreshSlots()
        guard isReady, !slots.isEmpty else { return nil }
        return store.saveAllFromCamera(slots)
    }

    func write(_ recipe: Recipe, to slot: Int) async -> PresetService.WriteReport? {
        guard let service else { return nil }
        busy = "writing c\(slot)"
        defer { busy = nil }
        do {
            let base = slots.first { $0.slot == slot }
            let report = try await service.write(recipe, to: slot, base: base)
            note("c\(slot): wrote \(report.written)/\(report.attempted)")
            report.rejected.forEach { note("  rejected \($0)") }
            if let fresh = try? await service.readSlot(slot) {
                if let i = slots.firstIndex(where: { $0.slot == slot }) { slots[i] = fresh } else { slots.append(fresh) }
            }
            return report
        } catch {
            fail(error)
            return nil
        }
    }

    private func note(_ s: String) {
        AppLog.write(.usb, s)
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func fail(_ error: Error) {
        let msg = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        note("fault: \(msg)")
        phase = .fault(msg)
    }

    fileprivate func attach(_ cam: ICCameraDevice) {
        guard camera == nil else { return }
        camera = cam
        cam.delegate = self
        phase = .opening(cam.name ?? "camera")
        note("found \(cam.name ?? "camera")")
        cam.requestOpenSession()
    }

    fileprivate func sessionReady(_ cam: ICCameraDevice) {
        guard cam === camera else { return }
        let name = cam.name ?? "camera"
        service = PresetService(session: PTPSession(transport: ICCPTPTransport(camera: cam), trace: { AppLog.write(.usb, $0) }))
        phase = .ready(name)
        note("session open with \(name)")
        Task { await refreshSlots() }
    }

    fileprivate func detach(_ device: ICDevice) {
        guard device === camera else { return }
        note("camera unplugged")
        camera = nil
        service = nil
        slots = []
        phase = .searching
    }

    fileprivate func openFailed(_ error: Error) {
        fail(error)
    }
}

extension USBCameraController: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        Task { @MainActor in self.attach(cam) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.detach(device) }
    }
}

extension USBCameraController: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.detach(device) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.openFailed(error) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.sessionReady(device) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
}

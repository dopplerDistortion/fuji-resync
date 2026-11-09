import Foundation
import ImageCaptureCore
import ImageIO
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
        /// USB CARD READER mode: the card's photos are listed, but custom settings can't be reached.
        case cardOnly(String)
        case fault(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var slots: [CameraPreset] = []
    private(set) var busy: String?
    /// The camera's serial number, when ImageCaptureCore reports one. Ties backups to a body.
    private(set) var serial: String?
    private(set) var log: [String] = []

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var camera: ICCameraDevice?
    @ObservationIgnored private var service: PresetService?

    var isReady: Bool { if case .ready = phase { return true } else { return false } }
    /// The card can be read: in either USB mode the camera is open.
    var cardOpen: Bool {
        switch phase {
        case .ready, .cardOnly: return true
        default: return false
        }
    }

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard phase == .idle || phase == .needsPermission || { if case .fault = phase { return true }; return false }() else { return }
        #if targetEnvironment(simulator)
        // ImageCaptureCore's control authorization raises on the simulator, and there's no USB anyway.
        phase = .searching
        return
        #else
        browser.requestControlAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if status == .authorized {
                    self.phase = .searching
                    if !self.browser.isBrowsing { self.browser.start() }
                    self.requestContents()
                } else {
                    self.phase = .needsPermission
                }
            }
        }
        #endif
    }

    /// Photos on the card are a separate permission from camera control: without it the card
    /// lists no files, so the map has nothing to pin.
    private(set) var contentsAllowed: Bool?

    private func requestContents() {
        #if !targetEnvironment(simulator)
        browser.requestContentsAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.contentsAllowed = status == .authorized
                self.note("photo access: \(status == .authorized ? "allowed" : "not allowed")")
            }
        }
        #endif
    }

    func stop() {
        browser.stop()
        camera?.requestCloseSession()
        camera = nil
        service = nil
        slots = []
        serial = nil
        phase = .idle
    }

    func refreshSlots() async {
        guard let service else { return }
        busy = "reading c1–c7"
        defer { busy = nil }
        do {
            slots = try await service.readAll()
            note("read \(slots.count) custom settings")
        } catch PresetService.PresetError.unsupported {
            if let name = camera?.name { phase = .cardOnly(name) }
            note("card reader mode: photos only. recipes need usb raw conv. / backup restore")
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

    /// Reads the GPS of every photo on the card that isn't in `skipping`, newest first. A RAF whose
    /// JPEG or HEIF sits beside it is skipped, so one shot is one place. Returns the places found
    /// and the files read for sure, with or without GPS; a file whose read failed is left to try
    /// again next time.
    func readPhotoPlaces(skipping: Set<String>, limit: Int = 1500) async -> (places: [PhotoPlace], checked: Set<String>, taken: [String: Date]) {
        guard cardOpen, let camera else { return ([], [], [:]) }
        let all = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let photos = all.filter { Self.kind(of: $0.name ?? "") != nil }
        let developed = Set(photos.compactMap { f -> String? in
            let n = (f.name ?? "").lowercased()
            return Self.kind(of: n) == .raw ? nil : Self.stem(n)
        })
        let shots = photos.filter { f in
            let n = (f.name ?? "").lowercased()
            return !(Self.kind(of: n) == .raw && developed.contains(Self.stem(n)))
        }
        let files = shots.filter { !skipping.contains(($0.name ?? "").lowercased()) }.suffix(limit)
        note("card: \(all.count) files listed, \(photos.count) photos (\(photos.count - shots.count) raw beside a jpeg, skipped), \(files.count) not read yet"
            + (contentsAllowed == false ? " · photo access not allowed" : ""))
        guard !files.isEmpty else { return ([], [], [:]) }
        busy = "reading photo locations"
        defer { busy = nil }
        var found: [PhotoPlace] = []
        var checked: Set<String> = []
        var taken: [String: Date] = [:]
        var failed = 0
        var described = 0
        for f in files.reversed() {
            let name = (f.name ?? "").lowercased()
            let (meta, error) = await Self.metadata(of: f)
            var props = meta
            var how = "metadata"
            // ImageCaptureCore can answer with no EXIF, or with EXIF but no {GPS}; then read the
            // file's own header, which has the GPS if the camera wrote it.
            if !(props.map(Self.hasGPS) ?? false),
               let header = await Self.headerProperties(of: f, kind: Self.kind(of: name) ?? .jpeg),
               Self.hasImageProperties(header) {
                props = header
                how = "header"
            }
            if described < 2 {
                described += 1
                let keys = (meta?.keys.map { "\($0)" }.sorted() ?? []).joined(separator: ",")
                note("\(name): metadata keys [\(keys)]" + (error.map { " error \($0.localizedDescription)" } ?? "")
                    + " · read by \(how): " + (props.map { Self.hasGPS($0) ? "gps" : "no gps" } ?? "nothing"))
            }
            guard let props, Self.hasImageProperties(props) else { failed += 1; continue }
            checked.insert(name)
            if let t = PhotoPlace.takenDate(metadata: props) ?? PhotoPlace.takenDate(metadata: meta) { taken[name] = t }
            if let place = PhotoPlace.from(file: name, metadata: props) { found.append(place) }
        }
        note("photo locations: \(found.count) of \(checked.count) files have gps"
            + (failed > 0 ? " · \(failed) could not be read" : ""))
        return (found, checked, taken)
    }

    private enum PhotoKind { case jpeg, heif, raw }

    private static func kind(of name: String) -> PhotoKind? {
        let n = name.lowercased()
        if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") { return .jpeg }
        if n.hasSuffix(".hif") || n.hasSuffix(".heif") || n.hasSuffix(".heic") { return .heif }
        if n.hasSuffix(".raf") { return .raw }
        return nil
    }

    private static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private static func metadata(of f: ICCameraFile) async -> ([AnyHashable: Any]?, Error?) {
        await withCheckedContinuation { cont in
            f.requestMetadataDictionary(options: [:]) { dict, error in cont.resume(returning: (dict, error)) }
        }
    }

    private static func hasImageProperties(_ p: [AnyHashable: Any]?) -> Bool {
        guard let p else { return false }
        return p[kCGImagePropertyExifDictionary as String] != nil || p[kCGImagePropertyGPSDictionary as String] != nil
            || p[kCGImagePropertyTIFFDictionary as String] != nil
    }

    private static func hasGPS(_ p: [AnyHashable: Any]) -> Bool {
        p[kCGImagePropertyGPSDictionary as String] != nil
    }

    private static func read(_ f: ICCameraFile, at offset: off_t, length: off_t) async -> Data? {
        await withCheckedContinuation { cont in
            f.requestReadData(atOffset: offset, length: length) { data, _ in cont.resume(returning: data) }
        }
    }

    /// EXIF sits in the first few KB of a JPEG. A RAF keeps a full JPEG preview at the offset in
    /// its header (bytes 84–91, big-endian). HEIF can keep it further in, so it gets more.
    private static func headerProperties(of f: ICCameraFile, kind: PhotoKind) async -> [AnyHashable: Any]? {
        var start: off_t = 0
        var length: off_t = 256 * 1024
        switch kind {
        case .jpeg: break
        case .heif: length = 1024 * 1024
        case .raw:
            guard let head = await read(f, at: 0, length: 100), head.count >= 92 else { return nil }
            let bytes = [UInt8](head)
            let be = { (i: Int) -> UInt32 in bytes[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
            start = off_t(be(84))
            length = off_t(min(be(88), 256 * 1024))
            guard start > 0, length > 0 else { return nil }
        }
        let size = off_t(f.fileSize)
        if size > 0 { length = min(length, size - start) }
        guard length > 0, let data = await read(f, at: start, length: length) else { return nil }
        let src = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(src, data as CFData, false)
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [AnyHashable: Any]
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
        serial = cam.serialNumberString.flatMap { $0.isEmpty ? nil : $0 }
        let service = PresetService(session: PTPSession(transport: ICCPTPTransport(camera: cam), trace: { AppLog.write(.usb, $0) }))
        self.service = service
        note("session open with \(name)")
        // Ready only once C1–C7 read, so the queue never writes to a camera that can't take it.
        Task {
            busy = "reading c1–c7"
            defer { busy = nil }
            do {
                slots = try await service.readAll()
                guard camera === cam else { return }
                phase = .ready(name)
                note("read \(slots.count) custom settings")
            } catch PresetService.PresetError.unsupported {
                guard camera === cam else { return }
                // USB CARD READER mode: the card is there, the custom settings aren't.
                phase = .cardOnly(name)
                note("card reader mode: photos only. recipes need usb raw conv. / backup restore")
            } catch {
                fail(error)
            }
        }
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

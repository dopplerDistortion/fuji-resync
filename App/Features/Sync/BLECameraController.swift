import Foundation
import CoreBluetooth
import CoreLocation
import Observation
import FujiKit

/// Bluetooth link to the camera: pairing, automatic location + time sync, and a shutter remote.
///
/// The camera asks for a location over the geotag-request characteristic, about every 10 s while
/// linked (not once per photo); we answer with the
/// phone's latest fix. iOS keeps this running in the background thanks to the
/// `bluetooth-central` and `location` background modes.
@MainActor
@Observable
final class BLECameraController: NSObject {
    enum Phase: Equatable {
        case off
        case unauthorized
        case idle
        case scanning
        case connecting(String)
        case linked(String)
        case fault(String)
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        let pairing: FujiBLE.PairingKind
        let rssi: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var discovered: [Discovered] = []
    private(set) var lastSync: Date?
    private(set) var lastSentLocation: CLLocation?
    private(set) var syncCount = 0
    private(set) var log: [String] = []
    var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: Keys.autoSync); location.setActive(autoSync && isLinked) }
    }

    @ObservationIgnored let location = LocationProvider()
    /// Called with every location sent to the camera, for the map's trail.
    @ObservationIgnored var onGeotag: (@MainActor (CLLocation) -> Void)?
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [String: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingPairing: FujiBLE.PairingKind?
    /// Handshake sent on this connection; we wait for the camera to talk back before calling it linked.
    @ObservationIgnored private var handshakeSent = false
    /// Drops in a row before the camera accepted us. Drives the reconnect backoff.
    @ObservationIgnored private var failedLinks = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// The running Bluetooth backup download (experiment T1), if any.
    @ObservationIgnored private var backup: FujiBLEBackup.Download?
    @ObservationIgnored private var backupWatchdog: Task<Void, Never>?
    @ObservationIgnored private var backupStartedAt = Date()
    /// What the last backup attempt did, for the log tab.
    private(set) var backupStatus: String?
    private(set) var backupRunning = false
    /// The raw `backup.dat` and the GATT inventory from the last attempt.
    private(set) var backupFiles: [URL] = []

    private enum Keys {
        static let saved = "ble.savedPeripheral"
        static let token = "ble.token"
        static let serial = "ble.serial"
        static let autoSync = "ble.autoSync"
    }

    var isLinked: Bool { if case .linked = phase { return true } else { return false } }
    var savedCameraID: UUID? { UserDefaults.standard.string(forKey: Keys.saved).flatMap(UUID.init) }

    override init() {
        autoSync = UserDefaults.standard.object(forKey: Keys.autoSync) as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "ing.goksen.resync.ble",
        ])
    }

    // MARK: Actions

    func scan() {
        guard central.state == .poweredOn else { return }
        discovered = []
        phase = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("scanning. on the camera: menu → network/usb setting → bluetooth settings → pairing registration.")
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self.phase == .scanning { self.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func pair(_ d: Discovered) {
        stopScan()
        guard let p = central.retrievePeripherals(withIdentifiers: [d.id]).first else { return }
        pendingPairing = d.pairing
        connect(p, name: d.name)
    }

    /// Reconnect to the saved camera. iOS keeps the request pending until the camera is in range.
    func reconnect() {
        guard central.state == .poweredOn, let id = savedCameraID,
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(p, name: p.name ?? "camera")
    }

    func forget() {
        reconnectTask?.cancel(); reconnectTask = nil
        failedLinks = 0
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        [Keys.saved, Keys.token, Keys.serial].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        location.setActive(false)
        phase = .idle
        note("forgot camera. also remove the phone from the camera's bluetooth list.")
    }

    /// Sends the current fix right now, without waiting for the camera to ask.
    func syncNow() {
        if let loc = location.latest { send(loc, force: true) } else { location.requestOneShot { [weak self] l in self?.send(l, force: true) } }
    }

    // MARK: Shutter

    func shutter() async {
        guard let p = peripheral, let c = characteristics[FujiBLE.Characteristic.shutter] else {
            note("shutter not available on this link")
            return
        }
        p.writeValue(FujiBLE.Shutter.command, for: c, type: .withResponse)
        p.writeValue(FujiBLE.Shutter.press, for: c, type: .withResponse)
        try? await Task.sleep(nanoseconds: 150_000_000)
        p.writeValue(FujiBLE.Shutter.command, for: c, type: .withResponse)
        p.writeValue(FujiBLE.Shutter.release, for: c, type: .withResponse)
    }

    enum ShutterAction { case half, press, release }

    /// One step of a held shutter: half-press to focus, press to fire (and hold for bulb), release.
    func shutter(_ action: ShutterAction) {
        guard let p = peripheral, let c = characteristics[FujiBLE.Characteristic.shutter] else {
            note("shutter not available on this link")
            return
        }
        let value: Data
        switch action {
        case .half: value = FujiBLE.Shutter.halfPress
        case .press: value = FujiBLE.Shutter.press
        case .release: value = FujiBLE.Shutter.release
        }
        p.writeValue(FujiBLE.Shutter.command, for: c, type: .withResponse)
        p.writeValue(value, for: c, type: .withResponse)
    }

    var canShutter: Bool { isLinked && characteristics[FujiBLE.Characteristic.shutter] != nil }

    // MARK: Bluetooth backup (experiment T1)

    /// Downloads `backup.dat` read-only and saves it with a list of every service and
    /// characteristic the camera offers. It never writes camera settings.
    func downloadBackup() {
        guard let p = peripheral, isLinked else { backupStatus = "pair and link the camera first"; return }
        guard !backupRunning else { return }
        let inventory = gattInventory(p)
        backupFiles = [saveBackupFile("gatt", ext: "txt", data: Data(inventory.utf8))].compactMap { $0 }
        var d = FujiBLEBackup.Download()
        let actions = d.start(available: Set(characteristics.keys))
        backup = d
        backupRunning = true
        backupStartedAt = Date()
        backupStatus = "asking the camera for its backup"
        note("backup: started, \(characteristics.count) characteristics on this camera")
        perform(actions, on: p)
        armBackupWatchdog()
    }

    private func gattInventory(_ p: CBPeripheral) -> String {
        var lines = ["resync gatt inventory", "camera: \(p.name ?? "?") \(p.identifier.uuidString)", "date: \(ISO8601DateFormatter().string(from: Date()))", ""]
        for s in p.services ?? [] {
            lines.append("service \(s.uuid.uuidString)")
            for c in s.characteristics ?? [] {
                lines.append("  \(c.uuid.uuidString)  \(Self.describe(c.properties))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ p: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [(.read, "read"), (.write, "write"), (.writeWithoutResponse, "write-no-rsp"),
                                                             (.notify, "notify"), (.indicate, "indicate")]
        return names.filter { p.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    private func perform(_ actions: [FujiBLEBackup.Action], on p: CBPeripheral) {
        for a in actions {
            switch a {
            case let .subscribe(id):
                if let c = characteristics[id] { p.setNotifyValue(true, for: c) }
            case let .write(id, value):
                guard let c = characteristics[id] else { note("backup: no \(id.prefix(8)) to write"); continue }
                AppLog.write(.ble, "backup → \(id.prefix(8)) \(value.hex)")
                p.writeValue(value, for: c, type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
            case let .read(id):
                if let c = characteristics[id] { p.readValue(for: c) }
            case let .finished(r):
                endBackup()
                let file = saveBackupFile("backup", ext: "dat", data: r.data)
                if let file { backupFiles.append(file) }
                let sum = r.checksum.map { String(format: "checksum %04x ok", $0) } ?? "no checksum sent"
                let secs = Int(Date().timeIntervalSince(backupStartedAt))
                backupStatus = "got \(r.name): \(r.data.count) bytes in \(secs) s, \(sum)"
                note("backup: \(backupStatus!)" + (r.reportedSize.map { ", camera said \($0) bytes" } ?? ""))
            case let .failed(why):
                endBackup()
                backupStatus = "failed: \(why)"
                note("backup: \(why)")
            }
        }
    }

    /// The camera notifies every piece; if it goes quiet for 20 s, give up.
    private func armBackupWatchdog() {
        backupWatchdog?.cancel()
        backupWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled, self.backupRunning, var d = self.backup, let p = self.peripheral else { return }
            let actions = d.timedOut()
            self.backup = d
            self.perform(actions, on: p)
        }
    }

    private func endBackup() {
        backupRunning = false
        backupWatchdog?.cancel(); backupWatchdog = nil
        backup = nil
    }

    private func backupDidUpdate(_ id: String, value: Data, on p: CBPeripheral) -> Bool {
        guard backupRunning, FujiBLEBackup.Characteristic.all.contains(id), var d = backup else { return false }
        let actions = d.receive(value, from: id)
        backup = d
        if d.phase == .transferring || d.phase == .finishing {
            backupStatus = "receiving: \(d.received) bytes, \(d.chunks) pieces"
        }
        armBackupWatchdog()
        perform(actions, on: p)
        return true
    }

    private func saveBackupFile(_ prefix: String, ext: String, data: Data) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ble-backups", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(prefix)-\(f.string(from: Date())).\(ext)")
        do { try data.write(to: url, options: .atomic); return url } catch {
            note("backup: couldn't save \(prefix): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Internals

    private func connect(_ p: CBPeripheral, name: String) {
        // One connection attempt at a time: a second connect while iOS is still connecting
        // made the camera drop the link during first pairing.
        if peripheral === p, p.state == .connecting || p.state == .connected {
            AppLog.write(.ble, "connect skipped, already \(p.state == .connected ? "connected" : "connecting")")
            return
        }
        reconnectTask?.cancel(); reconnectTask = nil
        handshakeSent = false
        peripheral = p
        p.delegate = self
        characteristics = [:]
        phase = .connecting(name)
        central.connect(p, options: nil)
    }

    private func send(_ loc: CLLocation, force: Bool = false) {
        guard let p = peripheral, let c = characteristics[FujiBLE.Characteristic.geotagWrite] else { return }
        // One answer per camera request: a pending one-shot fix can land right after we already replied.
        if !force, let last = lastSync, Date().timeIntervalSince(last) < 2 { return }
        let packet = FujiBLE.geotagPacket(
            latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : 0, date: Date()
        )
        p.writeValue(packet, for: c, type: .withResponse)
        note(String(format: "geotag → %.5f, %.5f ±%.0fm", loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy))
        lastSync = Date()
        lastSentLocation = loc
        onGeotag?(loc)
        syncCount += 1
    }

    private func didDiscoverServices(_ p: CBPeripheral) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    private func didDiscoverCharacteristics(_ p: CBPeripheral, service: CBService) {
        for c in service.characteristics ?? [] { characteristics[c.uuid.uuidString.uppercased()] = c }
        // Wait until the services we need are in.
        let have = Set(characteristics.keys)
        let needed: Set<String> = [FujiBLE.Characteristic.geotagWrite, FujiBLE.Characteristic.geotagRequest]
        guard needed.isSubset(of: have), !handshakeSent else { return }
        handshakeSent = true
        handshake(p)
    }

    private func handshake(_ p: CBPeripheral) {
        let C = FujiBLE.Characteristic.self
        let pairing = pendingPairing ?? savedPairing()

        switch pairing {
        case let .legacy(token)?:
            if let c = characteristics[C.pairToken] { p.writeValue(token, for: c, type: .withResponse) }
        case .secure?:
            if let c = characteristics[C.secureStatus] { p.readValue(for: c) } // ack in didUpdateValue
        case nil:
            break
        }
        if let c = characteristics[C.clientIdentity] { p.writeValue(Data("resync".utf8), for: c, type: .withResponse) }

        for id in [C.indication1, C.indication2, C.notification1, C.geotagRequest, C.indication3, C.geotagSyncInterval] {
            if let c = characteristics[id], c.properties.contains(.notify) || c.properties.contains(.indicate) {
                p.setNotifyValue(true, for: c)
            }
        }
        if let c = characteristics[C.geotagSyncInterval] {
            var w = ByteWriter(); w.u16(FujiBLE.geotagSyncIntervalSeconds)
            p.writeValue(w.data, for: c, type: .withResponse)
        }

        UserDefaults.standard.set(p.identifier.uuidString, forKey: Keys.saved)
        switch pairing {
        case let .legacy(token)?: UserDefaults.standard.set(token, forKey: Keys.token)
        case let .secure(serial)?: UserDefaults.standard.set(serial, forKey: Keys.serial)
        case nil: break
        }
        note("handshake sent, waiting for the camera")
        // Normally the camera answers with a notification within a second. If it stays quiet
        // but keeps the link up, treat that as accepted too.
        Task { [weak self, weak p] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, let p, p === self.peripheral, p.state == .connected else { return }
            self.confirmLink(p, reason: "link held 4 s")
        }
    }

    /// Marks the link as live once the camera has shown it accepted the handshake.
    private func confirmLink(_ p: CBPeripheral, reason: String) {
        guard handshakeSent, !isLinked else { return }
        pendingPairing = nil
        failedLinks = 0
        phase = .linked(p.name ?? "camera")
        note("linked to \(p.name ?? "camera") (\(reason))")
        location.setActive(autoSync)
    }

    private func savedPairing() -> FujiBLE.PairingKind? {
        if let t = UserDefaults.standard.data(forKey: Keys.token) { return .legacy(token: t) }
        if let s = UserDefaults.standard.data(forKey: Keys.serial) { return .secure(serial: s) }
        return nil
    }

    private func didUpdate(_ c: CBCharacteristic, value: Data, on p: CBPeripheral) {
        let id = c.uuid.uuidString.uppercased()
        // Backup pieces are 120 bytes each; log only their start.
        AppLog.write(.ble, "← \(id.prefix(8)) \(value.prefix(24).hex)\(value.count > 24 ? " … (\(value.count) b)" : "")")
        confirmLink(p, reason: "camera answered")
        if backupDidUpdate(id, value: value, on: p) { return }
        if id == FujiBLE.Characteristic.geotagRequest, value.starts(with: FujiBLE.geotagRequested) {
            guard autoSync else { return }
            if let loc = location.latest, loc.timestamp.timeIntervalSinceNow > -120 { send(loc) }
            else { location.requestOneShot { [weak self] l in self?.send(l) } }
        } else if id == FujiBLE.Characteristic.secureStatus, let ack = FujiBLE.secureStatusAck(value) {
            p.writeValue(ack, for: c, type: .withResponse)
        }
    }

    private func note(_ s: String) {
        AppLog.write(.ble, s)
        log.append(s)
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
}

extension BLECameraController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if phase == .off || phase == .unauthorized { phase = .idle }
                reconnect()
            case .unauthorized: phase = .unauthorized
            case .poweredOff: phase = .off
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
                peripheral = p
                p.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            guard let kind = FujiBLE.parseAdvertisement(manufacturerData: mfr, advertisedServices: services) else { return }
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "fujifilm"
            let d = Discovered(id: peripheral.identifier, name: name, pairing: kind, rssi: RSSI.intValue)
            if let i = discovered.firstIndex(where: { $0.id == d.id }) { discovered[i] = d } else { discovered.append(d) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("connected, discovering services")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("connect failed: \(error?.localizedDescription ?? "unknown")")
            phase = .fault("couldn't connect: \(error?.localizedDescription ?? "unknown"). put the camera in pairing mode and scan again.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            // After forget we dropped the peripheral on purpose; its disconnect isn't a failed link.
            guard peripheral === self.peripheral else { note("disconnected"); return }
            let wasLinked = isLinked
            note("disconnected\(wasLinked ? "" : " before the camera accepted")" + (error.map { ": \($0.localizedDescription)" } ?? ""))
            characteristics = [:]
            handshakeSent = false
            location.setActive(false)
            if backupRunning {
                endBackup()
                backupStatus = "failed: the link dropped during the backup"
            }
            if !wasLinked { failedLinks += 1 }
            let pairingFailed = pendingPairing != nil && failedLinks >= 3
            if pairingFailed {
                pendingPairing = nil
                phase = .fault("the camera keeps dropping the link. on the camera, delete this phone from bluetooth settings, start pairing registration again, then scan.")
                return
            }
            phase = .idle
            // Ask iOS to reconnect when the camera is back. Back off if it keeps dropping us.
            guard savedCameraID == peripheral.identifier || pendingPairing != nil else { return }
            let delay = min(30, failedLinks == 0 ? 1 : 2 << min(failedLinks, 4))
            AppLog.write(.ble, "reconnecting in \(delay) s")
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.connect(peripheral, name: peripheral.name ?? "camera")
            }
        }
    }
}

extension BLECameraController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { didDiscoverServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let v = characteristic.value else { return }
            didUpdate(characteristic, value: v, on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            let id = characteristic.uuid.uuidString.uppercased()
            note("write \(id.prefix(8)) failed: \(error.localizedDescription)")
            // The finish/abort write is best effort; any other failed write stops the backup.
            if backupRunning, FujiBLEBackup.Characteristic.all.contains(id), id != FujiBLEBackup.Characteristic.fileTransferResult {
                endBackup()
                backupStatus = "failed: the camera refused \(id.prefix(8)): \(error.localizedDescription)"
            }
        }
    }
}

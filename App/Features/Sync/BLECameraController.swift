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

    /// The read-only Bluetooth backup test (log tab).
    private(set) var backupTest: BackupTest = .idle
    /// Each waiter carries a ticket, so a timeout left over from an earlier wait can't end a newer one.
    @ObservationIgnored private var readWaiters: [String: (ticket: Int, cont: CheckedContinuation<Data, Error>)] = [:]
    @ObservationIgnored private var writeWaiters: [String: (ticket: Int, cont: CheckedContinuation<Void, Error>)] = [:]
    @ObservationIgnored private var valueWaiters: [String: (ticket: Int, cont: CheckedContinuation<Data?, Never>)] = [:]
    @ObservationIgnored private var tickets = 0
    /// Notifications that arrived before anyone waited for them, per characteristic the backup watches.
    @ObservationIgnored private var inbox: [String: [Data]] = [:]

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
        if let waiter = readWaiters.removeValue(forKey: id) {
            waiter.cont.resume(returning: value)
            return
        }
        AppLog.write(.ble, "← \(id.prefix(8)) \(value.hex)")
        if inbox[id] != nil {
            if let waiter = valueWaiters.removeValue(forKey: id) { waiter.cont.resume(returning: value) } else { inbox[id]?.append(value) }
        }
        confirmLink(p, reason: "camera answered")
        if id == FujiBLE.Characteristic.geotagRequest, value.starts(with: FujiBLE.geotagRequested) {
            guard autoSync else { return }
            if let loc = location.latest, loc.timestamp.timeIntervalSinceNow > -120 { send(loc) }
            else { location.requestOneShot { [weak self] l in self?.send(l) } }
        } else if id == FujiBLE.Characteristic.secureStatus, let ack = FujiBLE.secureStatusAck(value) {
            p.writeValue(ack, for: c, type: .withResponse)
        }
    }

    // MARK: Bluetooth backup test (read only)

    enum BackupTest: Equatable {
        case idle
        case running(String)
        case done(BackupResult)
        case failed(String)
    }

    struct BackupResult: Equatable {
        let name: String
        let bytes: Int
        let pieces: Int
        /// nil when the camera sent no sum.
        let checksumOK: Bool?
        let file: URL
        let inventory: URL
        /// Filled when the file unpacks into a layout FujiKit knows.
        var unpacked: Int?
        var slotNames: [String] = []
        var parseError: String?
    }

    var backupRunning: Bool { if case .running = backupTest { return true } else { return false } }

    /// Every service and characteristic the camera offers on this link, with its properties.
    func gattInventory() -> String {
        guard let p = peripheral else { return "no camera connected" }
        var lines = ["\(p.name ?? "camera") \(p.identifier.uuidString)"]
        for s in p.services ?? [] {
            lines.append("service \(s.uuid.uuidString)")
            for c in s.characteristics ?? [] {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("R") }
                if c.properties.contains(.write) { props.append("W") }
                if c.properties.contains(.writeWithoutResponse) { props.append("w") }
                if c.properties.contains(.notify) { props.append("N") }
                if c.properties.contains(.indicate) { props.append("I") }
                lines.append("  \(c.uuid.uuidString) \(props.joined())")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Downloads the camera's settings backup (`backup.dat`) over the current link and saves the raw
    /// bytes. Read only: the camera is asked for a copy of its settings and nothing is written to them.
    func runBackupTest() async {
        guard !backupRunning else { return }
        guard isLinked, let p = peripheral else {
            backupTest = .failed("connect the camera over bluetooth first.")
            return
        }
        let B = FujiBLE.Backup.self
        backupTest = .running("checking the camera's services")
        let inventory = gattInventory()
        AppLog.write(.ble, "backup test: gatt inventory\n" + inventory)
        let stamp = Self.stamp.string(from: Date())
        let inventoryURL = Self.saveTestFile(Data(inventory.utf8), name: "\(stamp) gatt.txt")

        let missing = B.required.filter { characteristics[$0] == nil }
        guard missing.isEmpty else {
            let list = missing.map { String($0.prefix(8)).lowercased() }.joined(separator: ", ")
            note("backup test: camera doesn't offer \(list)")
            backupTest = .failed("the camera doesn't offer the backup characteristics (\(list)) on this link. share the gatt list so we can see what it has.")
            return
        }

        for id in [B.transactionState, B.state] {
            inbox[id] = []
            if let c = characteristics[id], !c.isNotifying { p.setNotifyValue(true, for: c) }
        }
        defer { inbox[B.transactionState] = nil; inbox[B.state] = nil }
        try? await Task.sleep(nanoseconds: 400_000_000)

        do {
            backupTest = .running("asking for the backup")
            try await write(B.request, B.settings)
            note("backup test: requested settings backup")
            guard let ready = await nextValue(B.state, timeout: 10) else { throw BackupTestError("the camera didn't answer the backup request in 10 s.") }
            note("backup test: backup state \(ready.hex)")
            guard ready.first == 1 else { throw BackupTestError("the camera says it's busy (state \(ready.hex)). leave its menus and try again.") }

            var size = ByteWriter(); size.u32(B.pieceSize)
            try await write(B.partialSize, size.data)
            var index = ByteWriter(); index.u32(0)
            try await write(B.transferIndex, index.data)

            var assembler = B.Assembler()
            var name = "backup.dat"
            var reported: Int?
            loop: while true {
                guard let v = await nextValue(B.transactionState, timeout: 20), let code = B.stateCode(v) else {
                    throw BackupTestError("the transfer stalled after \(assembler.data.count) bytes.")
                }
                switch code {
                case 1, 2:
                    let piece = try await read(B.partialData)
                    if assembler.pieces < 3 { AppLog.write(.ble, "backup test: piece \(assembler.pieces) \(piece.prefix(24).hex)") }
                    try assembler.add(piece)
                    backupTest = .running("receiving · \(assembler.data.count) bytes")
                case 3:
                    if let info = try? await read(B.information), let parsed = B.information(info) {
                        if !parsed.name.isEmpty { name = parsed.name }
                        reported = parsed.size
                        note("backup test: file info \(parsed.name) \(parsed.size) bytes")
                    }
                    break loop
                default:
                    throw BackupTestError("the camera ended the transfer (state \(v.hex)) after \(assembler.data.count) bytes.")
                }
            }

            let file = assembler.file(size: reported)
            var ok: Bool?
            if assembler.isComplete {
                do { try assembler.verify(); ok = true } catch { ok = false }
            }
            try? await write(B.transferResult, ok == false ? B.abort : B.finish)
            let fileURL = Self.saveTestFile(file, name: "\(stamp) \(ok == false ? "badsum " : "")\(name)")
            note("backup test: \(name) \(file.count) bytes in \(assembler.pieces) pieces, checksum " + (ok.map { $0 ? "ok" : "mismatch \(String(format: "%04x", assembler.computed))" } ?? "absent"))
            guard let fileURL, let inventoryURL else { throw BackupTestError("got the backup but couldn't save it on the phone.") }
            var result = BackupResult(name: name, bytes: file.count, pieces: assembler.pieces, checksumOK: ok, file: fileURL, inventory: inventoryURL)
            do {
                let parsed = try SettingsBackup(file)
                result.unpacked = parsed.raw.count
                result.slotNames = parsed.slots.map(\.name)
                for slot in parsed.slots {
                    let (r, unmapped) = slot.decode()
                    AppLog.write(.ble, "backup test: c\(slot.slot) \(r.name) · \(r.filmSimulation.label.lowercased()) · not read yet: \(unmapped.joined(separator: ", "))")
                }
                note("backup test: unpacked \(parsed.raw.count) bytes, \(parsed.model) format \(parsed.format), slots " + parsed.slots.map { "c\($0.slot) \($0.name)" }.joined(separator: " · "))
            } catch {
                result.parseError = "\(error)"
                note("backup test: couldn't read the file: \(error)")
            }
            backupTest = .done(result)
        } catch {
            try? await write(B.transferResult, B.abort)
            let message = (error as? BackupTestError)?.message ?? "\(error)"
            note("backup test failed: \(message)")
            backupTest = .failed(message)
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    /// Saved under Application Support/ble-backups, so a test run survives a relaunch.
    private static func saveTestFile(_ data: Data, name: String) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ble-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private func read(_ id: String, timeout: Double = 10) async throws -> Data {
        guard let p = peripheral, let c = characteristics[id] else { throw BackupTestError("\(id.prefix(8)) isn't on this link.") }
        guard readWaiters[id] == nil else { throw BackupTestError("already reading \(id.prefix(8)).") }
        tickets += 1
        let ticket = tickets
        return try await withCheckedThrowingContinuation { cont in
            readWaiters[id] = (ticket, cont)
            p.readValue(for: c)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.readWaiters[id]?.ticket == ticket else { return }
                self.readWaiters.removeValue(forKey: id)?.cont.resume(throwing: BackupTestError("reading \(id.prefix(8)) timed out."))
            }
        }
    }

    private func write(_ id: String, _ value: Data, timeout: Double = 10) async throws {
        guard let p = peripheral, let c = characteristics[id] else { throw BackupTestError("\(id.prefix(8)) isn't on this link.") }
        AppLog.write(.ble, "→ \(id.prefix(8)) \(value.hex)")
        guard c.properties.contains(.write) else {
            p.writeValue(value, for: c, type: .withoutResponse)
            return
        }
        writeWaiters.removeValue(forKey: id)?.cont.resume(throwing: BackupTestError("superseded"))
        tickets += 1
        let ticket = tickets
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeWaiters[id] = (ticket, cont)
            p.writeValue(value, for: c, type: .withResponse)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.writeWaiters[id]?.ticket == ticket else { return }
                self.writeWaiters.removeValue(forKey: id)?.cont.resume(throwing: BackupTestError("writing \(id.prefix(8)) timed out."))
            }
        }
    }

    /// The next notification on a watched characteristic, or nil after the timeout.
    private func nextValue(_ id: String, timeout: Double) async -> Data? {
        if var queued = inbox[id], !queued.isEmpty {
            let v = queued.removeFirst()
            inbox[id] = queued
            return v
        }
        tickets += 1
        let ticket = tickets
        return await withCheckedContinuation { cont in
            valueWaiters.removeValue(forKey: id)?.cont.resume(returning: nil)
            valueWaiters[id] = (ticket, cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.valueWaiters[id]?.ticket == ticket else { return }
                self.valueWaiters.removeValue(forKey: id)?.cont.resume(returning: nil)
            }
        }
    }

    private func failWaiters(_ reason: String) {
        readWaiters.values.forEach { $0.cont.resume(throwing: BackupTestError(reason)) }
        writeWaiters.values.forEach { $0.cont.resume(throwing: BackupTestError(reason)) }
        valueWaiters.values.forEach { $0.cont.resume(returning: nil) }
        readWaiters = [:]; writeWaiters = [:]; valueWaiters = [:]
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
            failWaiters("the camera disconnected")
            location.setActive(false)
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
            let id = characteristic.uuid.uuidString.uppercased()
            if let error, let waiter = readWaiters.removeValue(forKey: id) {
                waiter.cont.resume(throwing: BackupTestError("reading \(id.prefix(8)) failed: \(error.localizedDescription)"))
                return
            }
            guard let v = characteristic.value else { return }
            didUpdate(characteristic, value: v, on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let id = characteristic.uuid.uuidString.uppercased()
            if let waiter = writeWaiters.removeValue(forKey: id) {
                if let error { waiter.cont.resume(throwing: BackupTestError("writing \(id.prefix(8)) failed: \(error.localizedDescription)")) } else { waiter.cont.resume() }
            }
            if let error { note("write \(characteristic.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)") }
        }
    }
}

struct BackupTestError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

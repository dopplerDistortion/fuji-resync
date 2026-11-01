import ActivityKit
import CoreLocation
import Foundation

/// "start shooting session": keeps the camera linked and location running while the phone is
/// in a pocket, and shows the session as a Live Activity. A background activity session keeps
/// When In Use location alive (iOS shows its indicator), which keeps resync running, so the
/// Bluetooth link answers the camera's geotag requests and the Live Activity stays current.
@MainActor
@Observable
final class ShootingSession {
    private(set) var startedAt: Date?
    /// The last session that ended, so the card's photos from it can be counted when the camera
    /// is next plugged in: Bluetooth doesn't report the camera's own shots.
    private(set) var last: DateInterval? = {
        let d = UserDefaults.standard
        guard let a = d.object(forKey: "session.lastStart") as? Date,
              let b = d.object(forKey: "session.lastEnd") as? Date, b >= a else { return nil }
        return DateInterval(start: a, end: b)
    }()
    /// Why the Live Activity couldn't start, if it couldn't. The session still runs without it.
    private(set) var fault: String?
    var isActive: Bool { startedAt != nil }
    /// Where each session's route is kept. Set once at launch.
    @ObservationIgnored var routes: SessionRoutes?

    @ObservationIgnored private var activity: Activity<SessionAttributes>?
    @ObservationIgnored private var background: CLBackgroundActivitySession?
    @ObservationIgnored private weak var ble: BLECameraController?
    @ObservationIgnored private weak var shutter: ShutterState?
    @ObservationIgnored private var firstShot = 0
    @ObservationIgnored private var firstGeotag = 0
    @ObservationIgnored private var lastState: SessionAttributes.ContentState?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    func start(ble: BLECameraController, shutter: ShutterState) {
        guard !isActive else { return }
        let now = Date()
        routes?.begin(at: now)
        bind(ble: ble, shutter: shutter, since: now)
        firstShot = shutter.shots
        firstGeotag = ble.syncCount
        if !ble.isLinked { ble.reconnect() }
        AppLog.write(.app, "shooting session started")
        Haptic.play(.medium)

        let state = snapshot()
        lastState = state
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let a = try Activity.request(
                    attributes: SessionAttributes(camera: cameraName, startedAt: now),
                    content: .init(state: state, staleDate: Self.stale()),
                    pushType: nil
                )
                adopt(a)
            } catch {
                fault = "the live activity didn't start: \(error.localizedDescription.lowercased())"
                AppLog.write(.app, "live activity failed: \(error.localizedDescription)")
            }
        } else {
            fault = "live activities are off for resync. turn them on in settings › resync."
        }
        track()
    }

    func end() {
        guard isActive else { return }
        let final = snapshot()
        if let since = startedAt {
            let span = DateInterval(start: since, end: max(since, Date()))
            last = span
            UserDefaults.standard.set(span.start, forKey: "session.lastStart")
            UserDefaults.standard.set(span.end, forKey: "session.lastEnd")
        }
        startedAt = nil
        background?.invalidate()
        background = nil
        ble?.location.onFixes = nil
        ble?.location.hold(false)
        let route = routes?.open.map { " · route \($0.distanceText), \($0.points.count) fixes" } ?? ""
        routes?.finish(at: Date())
        watcher?.cancel()
        watcher = nil
        heartbeat?.cancel()
        heartbeat = nil
        if let a = activity {
            Task { await a.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate) }
        }
        activity = nil
        fault = nil
        AppLog.write(.app, "shooting session ended · \(final.geotags) geotags · \(final.frames) fired from resync" + route)
        Haptic.play(.selection)
    }

    /// Picks up a session whose Live Activity outlived the last run of the app.
    func restore(ble: BLECameraController, shutter: ShutterState) {
        guard !isActive, let a = Activity<SessionAttributes>.activities.first else {
            // No session to pick up, so a route it left open ends where its fixes stopped.
            if !isActive { routes?.closeOpen() }
            return
        }
        routes?.resume(start: a.attributes.startedAt)
        bind(ble: ble, shutter: shutter, since: a.attributes.startedAt)
        let carried = a.content.state
        firstShot = shutter.shots - carried.frames
        firstGeotag = ble.syncCount - carried.geotags
        lastState = carried
        adopt(a)
        if !ble.isLinked { ble.reconnect() }
        AppLog.write(.app, "shooting session resumed")
        track()
        push(force: true)
    }

    // MARK: Internals

    private func bind(ble: BLECameraController, shutter: ShutterState, since: Date) {
        self.ble = ble
        self.shutter = shutter
        startedAt = since
        fault = nil
        background = CLBackgroundActivitySession()
        // Every fix while the session runs goes on its route, in the background too.
        ble.location.onFixes = { [weak self] fixes in self?.routes?.add(fixes) }
        ble.location.hold(true)
    }

    private func adopt(_ a: Activity<SessionAttributes>) {
        activity = a
        beat()
        watcher?.cancel()
        // Swiping the Live Activity away ends the session too.
        watcher = Task { [weak self] in
            for await state in a.activityStateUpdates where state == .dismissed || state == .ended {
                await MainActor.run {
                    guard let self, self.activity?.id == a.id else { return }
                    self.activity = nil
                    self.end()
                }
                break
            }
        }
    }

    private var cameraName: String {
        if case let .linked(n) = ble?.phase { return n.lowercased() }
        return "x-t30 ii"
    }

    private func snapshot() -> SessionAttributes.ContentState {
        guard let ble, let shutter else {
            return .init(link: .lost, geotags: 0, lastGeotag: nil, accuracy: nil, frames: 0, geotagOn: false)
        }
        let link: SessionAttributes.ContentState.Link
        switch ble.phase {
        case .linked: link = .linked
        case .connecting, .scanning: link = .searching
        default: link = .lost
        }
        return .init(
            link: link,
            geotags: max(0, ble.syncCount - firstGeotag),
            lastGeotag: ble.lastSync,
            accuracy: ble.lastSentLocation.map { Int($0.horizontalAccuracy.rounded()) },
            frames: max(0, shutter.shots - firstShot),
            geotagOn: ble.autoSync
        )
    }

    /// Re-arms on every change to what the Live Activity shows, in the foreground or not.
    private func track() {
        guard isActive else { return }
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.push()
                self?.track()
            }
        }
    }

    private func push(force: Bool = false) {
        guard isActive, let activity else { return }
        let s = snapshot()
        guard force || s != lastState else { return }
        lastState = s
        Task { await activity.update(.init(state: s, staleDate: Self.stale())) }
    }

    /// If resync stops (force quit, or iOS ends it), the Live Activity goes stale and says so
    /// rather than showing old numbers. A heartbeat keeps a live session fresh.
    private static func stale() -> Date { Date().addingTimeInterval(15 * 60) }

    private func beat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.push(force: true)
            }
        }
    }
}

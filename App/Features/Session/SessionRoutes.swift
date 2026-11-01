import CoreLocation
import Foundation

/// Where the phone went during one shooting session, as a step-tracking app records a walk.
struct SessionRoute: Codable, Identifiable, Hashable {
    struct Point: Codable, Hashable {
        var at: Date
        var latitude: Double
        var longitude: Double
        /// Horizontal accuracy, in metres.
        var accuracy: Double
    }

    var id = UUID()
    var start: Date
    /// Nil while the session is still running.
    var end: Date?
    var points: [Point] = []

    var isOpen: Bool { end == nil }
    var coordinates: [CLLocationCoordinate2D] { points.map { .init(latitude: $0.latitude, longitude: $0.longitude) } }

    /// Metres along the route.
    var distance: Double {
        zip(points, points.dropFirst()).reduce(0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    /// `1.2 km` or `340 m`.
    var distanceText: String {
        let d = distance
        return d < 1000 ? "\(Int(d.rounded())) m" : String(format: "%.1f km", d / 1000)
    }

    /// `1 nov · 14:02–15:40`, or `1 nov · 14:02–now` while it runs.
    var title: String {
        let day = start.formatted(.dateTime.day().month(.abbreviated)).lowercased()
        let from = start.formatted(date: .omitted, time: .shortened).lowercased()
        let to = end.map { $0.formatted(date: .omitted, time: .shortened).lowercased() } ?? "now"
        return "\(day) · \(from)–\(to)"
    }

    /// `1 h 38 min` or `12 min`.
    var durationText: String {
        let s = Int((end ?? Date()).timeIntervalSince(start))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

/// Every shooting session's route, kept on the phone. A session opens a route when it starts,
/// adds each good fix while it runs (in the background too) and closes it when it ends.
@MainActor
@Observable
final class SessionRoutes {
    /// Newest first.
    private(set) var routes: [SessionRoute] = []

    var open: SessionRoute? { routes.first { $0.isOpen } }

    private let url: URL
    @ObservationIgnored private var lastSave = Date.distantPast

    init(filename: String = "session-routes.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([SessionRoute].self, from: data) {
            routes = saved.sorted { $0.start > $1.start }
        }
    }

    /// A new session starts a new route; one left open by a session that didn't end cleanly is closed.
    func begin(at start: Date) {
        closeOpen()
        routes.insert(SessionRoute(start: start), at: 0)
        save()
    }

    /// A session picked up after relaunch carries on with its route, or starts one if it had none.
    func resume(start: Date) {
        if let i = routes.firstIndex(where: { $0.isOpen }), abs(routes[i].start.timeIntervalSince(start)) < 1 { return }
        begin(at: start)
    }

    func finish(at end: Date) {
        guard let i = routes.firstIndex(where: { $0.isOpen }) else { return }
        routes[i].end = max(routes[i].start, end)
        // A session that never got a fix leaves nothing to draw.
        if routes[i].points.isEmpty { routes.remove(at: i) }
        save()
    }

    /// Closes a route whose session is gone, at its last fix.
    func closeOpen() {
        guard let i = routes.firstIndex(where: { $0.isOpen }) else { return }
        finish(at: routes[i].points.last?.at ?? routes[i].start)
    }

    /// Keeps fixes that are recent, within 50 m and at least 5 m (or their accuracy) from the last
    /// one kept. Saves every half minute, so a crash loses little.
    func add(_ locations: [CLLocation]) {
        guard let i = routes.firstIndex(where: { $0.isOpen }) else { return }
        var changed = false
        for loc in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let acc = loc.horizontalAccuracy
            guard acc >= 0, acc <= 50,
                  loc.timestamp >= routes[i].start,
                  loc.timestamp.timeIntervalSinceNow > -120 else { continue }
            if let last = routes[i].points.last {
                guard loc.timestamp > last.at else { continue }
                let d = CLLocation(latitude: last.latitude, longitude: last.longitude).distance(from: loc)
                guard d >= max(5, min(acc, last.accuracy)) else { continue }
            }
            routes[i].points.append(.init(at: loc.timestamp, latitude: loc.coordinate.latitude,
                                          longitude: loc.coordinate.longitude, accuracy: acc))
            changed = true
        }
        if changed, Date().timeIntervalSince(lastSave) > 30 { save() }
    }

    func delete(_ id: SessionRoute.ID) {
        routes.removeAll { $0.id == id && !$0.isOpen }
        save()
    }

    #if DEBUG
    /// Two walks for the UI tests: one along the Galata side, one up İstiklal.
    func seedForUITests() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        func walk(_ start: Date, _ coords: [(Double, Double)]) -> SessionRoute {
            var r = SessionRoute(start: start, end: start.addingTimeInterval(Double(coords.count) * 120))
            r.points = coords.enumerated().map { i, c in
                .init(at: start.addingTimeInterval(Double(i) * 120), latitude: c.0, longitude: c.1, accuracy: 8)
            }
            return r
        }
        routes = [
            walk(base.addingTimeInterval(86_400), [(41.0322, 28.9772), (41.0335, 28.9790), (41.0350, 28.9805), (41.0369, 28.9850)]),
            walk(base, [(41.0256, 28.9744), (41.0259, 28.9760), (41.0262, 28.9787), (41.0270, 28.9801)]),
        ]
    }
    #endif

    private func save() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(routes) { try? data.write(to: url, options: .atomic) }
    }
}

import SwiftUI

/// The camera tab's `/session` panel: `session ┄┄ off [start shooting session]`, then
/// `■ 00:12:03 · on the lock screen [end]` with what it has done so far. A session keeps the
/// camera linked and geotags flowing with the phone in a pocket.
struct SessionPanel: View {
    @Environment(ShootingSession.self) private var session
    @Environment(BLECameraController.self) private var ble
    @Environment(ShutterState.self) private var shutter
    @Environment(PhotoPlaces.self) private var places
    @Environment(SessionRoutes.self) private var routes

    var body: some View {
        Panel(title: "session", meta: session.isActive ? "live activity" : "off") {
            VStack(alignment: .leading, spacing: 0) {
                if let since = session.startedAt {
                    HStack(spacing: 8) {
                        BlinkMark(color: Token.foreground)
                        Text(timerInterval: since ... Date.distantFuture, countsDown: false)
                            .font(Typeface.medium(15))
                            .monospacedDigit()
                        Text(session.fault == nil ? "· on the lock screen" : "· running")
                            .font(Typeface.body(13))
                            .foregroundStyle(Token.mutedForeground)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        FXButton("end", .outline, compact: true, haptic: .selection) { session.end() }
                            .accessibilityIdentifier("session.end")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    // `route ┄┄ 1.2 km · 84 fixes`, drawn on the shoot tab's map as it grows.
                    if let r = routes.open {
                        LeaderRow(label: "route", value: r.points.isEmpty ? "waiting for a fix" : "\(r.distanceText) · \(r.points.count) fix\(r.points.count == 1 ? "" : "es")",
                                  valueColor: r.points.isEmpty ? Token.mutedForeground : Token.foreground)
                            .accessibilityIdentifier("session.route")
                    }
                    if let fault = session.fault {
                        Text(fault)
                            .font(Typeface.body(12)).foregroundStyle(Token.signal)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.bottom, 10)
                    }
                } else {
                    if let last = session.last { lastLine(last) }
                    Text("keeps the camera linked and geotagged with the phone in a pocket, shows the link and geotags on the lock screen, and records your route for the shoot tab's map. the card counts its photos the next time the camera is plugged in.")
                        .font(Typeface.body(13))
                        .foregroundStyle(Token.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.top, 12)
                    FXButton("start shooting session", .outline, grow: true, haptic: .medium) {
                        session.start(ble: ble, shutter: shutter)
                    }
                    .accessibilityIdentifier("session.start")
                    .padding(14)
                }
            }
            .transaction { $0.animation = nil }
        }
    }

    /// `last ┄┄ 14:02–15:40 · 36 photos`, counted from the card. Until the card is read after the
    /// session, it says so.
    private func lastLine(_ span: DateInterval) -> some View {
        let range = span.start.formatted(date: .omitted, time: .shortened).lowercased() + "–"
            + span.end.formatted(date: .omitted, time: .shortened).lowercased()
        let read = (places.readAt ?? .distantPast) >= span.end
        let n = places.shotCount(from: span.start, to: span.end)
        return LeaderRow(label: "last", value: range + " · " + (read ? "\(n) photo\(n == 1 ? "" : "s")" : "plug in to count"),
                         valueColor: read ? Token.foreground : Token.mutedForeground)
            .padding(.horizontal, 14).padding(.top, 12)
            .accessibilityIdentifier("session.last")
    }
}

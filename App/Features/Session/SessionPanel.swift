import SwiftUI

/// The camera tab's `/session` panel: `session ┄┄ off [start shooting session]`, then
/// `■ 00:12:03 · on the lock screen [end]` with what it has done so far. A session keeps the
/// camera linked and geotags flowing with the phone in a pocket.
struct SessionPanel: View {
    @Environment(ShootingSession.self) private var session
    @Environment(BLECameraController.self) private var ble
    @Environment(ShutterState.self) private var shutter

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
                    if let fault = session.fault {
                        Text(fault)
                            .font(Typeface.body(12)).foregroundStyle(Token.signal)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.bottom, 10)
                    }
                } else {
                    Text("keeps the camera linked and geotagged with the phone in a pocket, and shows the link, geotags and frames on the lock screen.")
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
}

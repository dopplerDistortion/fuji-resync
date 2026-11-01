import UIKit
import SwiftUI

/// The shoot tab: shutter over Bluetooth (half-press, bulb, self-timer) and live view over Wi-Fi.
struct ShootView: View {
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(AppNav.self) private var nav

    var body: some View {
        Group {
            if case .off = ble.phase {
                faultScreen(title: "bluetooth", line: "bluetooth le ┄┄┄┄ off",
                            message: "bluetooth is off, so geotags and the shutter are paused. turn it on in control centre; resync picks the camera up again by itself.")
            } else if case .unauthorized = ble.phase {
                faultScreen(title: "bluetooth", line: "bluetooth le ┄┄┄┄ denied",
                            message: "resync isn't allowed to use bluetooth, so it can't reach the camera. allow it in settings › resync › bluetooth.",
                            settings: true)
            } else if nav.chromeHidden {
                FullBleed()
            } else {
                TabScreen(path: ["shoot"]) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if ble.savedCameraID == nil {
                                PairPanel()
                            } else if !ble.isLinked {
                                LinkLostPanel()
                            }
                            Viewfinder(expand: { nav.cut { nav.chromeHidden = true } })
                            WiFiPanel()
                            ShootFacts()
                        }
                        .padding(.horizontal, Token.gutter)
                        .padding(.vertical, 16)
                    }
                    .scrollIndicators(.hidden)
                } bottom: {
                    ShutterBar()
                }
            }
        }
        .background(Token.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func faultScreen(title: String, line: String, message: String, settings: Bool = false) -> some View {
        TabScreen(path: ["shoot"]) {
            ScreenFault(title: title, message: message, line: line) {
                if settings {
                    FXButton("open settings", .outline) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
    }
}

// MARK: Link lost

/// The camera is paired but not in range: not a fault, the camera is just off or asleep.
private struct LinkLostPanel: View {
    @Environment(BLECameraController.self) private var ble

    var body: some View {
        Panel(title: "link", meta: "paused") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if case .connecting = ble.phase { BlinkMark() } else if case .scanning = ble.phase { ScanGlyph() } else {
                        Text("■").foregroundStyle(Token.mark).accessibilityHidden(true)
                    }
                    Text(text).foregroundStyle(Token.mutedForeground)
                }
                .font(Typeface.body(13))
                Text("geotags and the shutter wait for the camera. switch it on; resync reconnects by itself.")
                    .font(Typeface.body(14)).fixedSize(horizontal: false, vertical: true)
                if case let .fault(msg) = ble.phase {
                    Text(msg).font(Typeface.body(13)).foregroundStyle(Token.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FXButton("reconnect now", .outline, compact: true) { ble.reconnect() }
            }
            .padding(14)
        }
        .feedIn()
    }

    private var text: String {
        switch ble.phase {
        case .connecting: return "reconnecting"
        case .scanning: return "looking for the camera"
        case .fault: return "link dropped"
        default: return "camera not in range"
        }
    }
}

// MARK: Viewfinder

private struct Viewfinder: View {
    var expand: () -> Void
    @Environment(WiFiRemoteController.self) private var wifi

    var body: some View {
        ZStack {
            Rectangle().fill(Token.card)
            if let f = wifi.frame {
                Image(uiImage: f).resizable().scaledToFit()
            } else {
                VStack(spacing: 6) {
                    Text(wifi.isLive ? "waiting for frames" : "no signal").systemLabel()
                    if !wifi.isLive {
                        Text("live view sleeps until you start it").font(Typeface.body(12)).foregroundStyle(Token.mark)
                    }
                }
            }
            ThirdsGrid().stroke(Token.foreground.opacity(0.18), lineWidth: 1)
            if wifi.isLive {
                VStack {
                    HStack {
                        StatusMark(state: .live, text: String(format: "live · %.0f fps", wifi.fps))
                        Spacer()
                        Text("⤢ full").font(Typeface.body(12)).foregroundStyle(Token.foreground)
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .aspectRatio(3 / 2, contentMode: .fit)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: 1))
        .cropMarks()
        .contentShape(Rectangle())
        .onTapGesture {
            guard wifi.isLive else { return }
            Haptic.play(.selection)
            expand()
        }
        .accessibilityLabel(wifi.frame == nil ? "no live view" : "live view")
        .accessibilityHint(wifi.isLive ? "opens full screen" : "")
    }
}

/// Live view edge to edge, with the shutter and a way back. The chrome stays hidden until then.
private struct FullBleed: View {
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(AppNav.self) private var nav

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let f = wifi.frame {
                Image(uiImage: f).resizable().scaledToFit()
            } else {
                Text(wifi.isLive ? "waiting for frames" : "live view stopped").systemLabel()
            }
            ThirdsGrid().stroke(Token.foreground.opacity(0.18), lineWidth: 1).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    StatusMark(state: wifi.isLive ? .live : .idle, text: wifi.isLive ? String(format: "live · %.0f fps", wifi.fps) : "stopped")
                    Spacer()
                    FXButton("exit", .outline, compact: true, haptic: .selection) { nav.cut { nav.chromeHidden = false } }
                }
                .padding(.horizontal, Token.gutter)
                .padding(.top, 8)
                Spacer()
                ShutterBar(floating: true)
            }
        }
        .statusBarHidden(true)
        .onChange(of: wifi.isLive) { _, live in if !live { nav.cut { nav.chromeHidden = false } } }
    }
}

struct ThirdsGrid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1 ... 2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

// MARK: Wi-Fi

private struct WiFiPanel: View {
    @Environment(WiFiRemoteController.self) private var wifi
    @AppStorage("wifiIdleMinutes") private var idle = 5

    var body: some View {
        Panel(title: "live view", meta: meta) {
            VStack(alignment: .leading, spacing: 12) {
                switch wifi.phase {
                case .idle:
                    Text("on the camera, open wireless communication. resync joins its FUJIFILM-… wi-fi and starts live view.")
                        .font(Typeface.body(14)).fixedSize(horizontal: false, vertical: true)
                    FXButton("start live view", grow: true) { start() }
                case .joining, .connecting:
                    log
                    FXButton("cancel", .outline, compact: true, haptic: .selection) { wifi.disconnect() }
                case .live:
                    Text("wi-fi closes \(idle) min after you leave this tab.")
                        .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    FXButton("stop live view", .secondary, compact: true) { wifi.disconnect() }
                case let .fault(msg):
                    FaultPanel(title: "wi-fi", message: msg, line: wifi.log.last.map { "> " + $0 }, action: ("try again", { start() }))
                }
            }
            .padding(14)
        }
    }

    private var meta: String {
        switch wifi.phase {
        case .idle: return "asleep"
        case .joining: return "joining"
        case .connecting: return "handshake"
        case .live: return "live"
        case .fault: return "stopped"
        }
    }

    /// The handshake as it happens, one typed line per step.
    private var log: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(wifi.log.suffix(4).enumerated()), id: \.offset) { _, line in
                TypedText(text: "> " + line.lowercased())
            }
            HStack(spacing: 0) {
                Text("> ")
                BlinkingCursor()
            }
        }
        .font(Typeface.diagram)
        .foregroundStyle(Token.mutedForeground)
        .lineLimit(1)
    }

    private func start() {
        Task { await wifi.connect(joinNetwork: true) }
    }
}

// MARK: Facts

private struct ShootFacts: View {
    @Environment(BLECameraController.self) private var ble
    @Environment(ShutterState.self) private var shutter

    var body: some View {
        VStack(spacing: 0) {
            LeaderRow(label: "geotag", value: geotag)
            LeaderRow(label: "shutter", value: shutter.route.label)
            LeaderRow(label: "shots this session", value: "\(shutter.shots)")
        }
        .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: 1) }
    }

    private var geotag: String {
        guard ble.isLinked else { return "paused" }
        guard ble.autoSync else { return "off" }
        guard let t = ble.lastSync else { return "waiting" }
        return "synced " + t.formatted(date: .omitted, time: .shortened).lowercased()
    }
}

// MARK: Shutter

/// Shots and route survive leaving the tab and going full screen.
@MainActor
@Observable
final class ShutterState {
    enum Route: Equatable {
        case bluetooth, wifi, none
        var label: String {
            switch self {
            case .bluetooth: return "bluetooth · half-press, bulb"
            case .wifi: return "wi-fi · tap only"
            case .none: return "no camera"
            }
        }
    }

    enum Press: Equatable { case idle, half, bulb(Date), countdown(Int), firing }

    var shots = 0
    var press: Press = .idle
    var timer = 0
    var route: Route = .none
}

/// The signal-red shutter. Touch down half-presses (focus), release fires. Hold past 1.1 s for
/// bulb: the shutter stays open until you let go. Slide off to cancel. The self-timer counts
/// down after release.
private struct ShutterBar: View {
    var floating = false
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(ShutterState.self) private var state
    @State private var holdTask: Task<Void, Never>?
    @State private var countTask: Task<Void, Never>?
    @State private var cancelled = false
    @State private var lastBulb: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bulbAfter = 1.1
    private static let cancelDistance: CGFloat = 24

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("timer").systemLabel()
                HStack(spacing: 0) {
                    ForEach([0, 2, 10], id: \.self) { t in
                        Button {
                            state.timer = t
                            Haptic.play(.selection)
                        } label: {
                            Text(t == 0 ? "off" : "\(t)s")
                                .font(Typeface.body(12))
                                .frame(minWidth: 44, minHeight: 32)
                                .foregroundStyle(state.timer == t ? Token.ink : Token.foreground)
                                .background(state.timer == t ? Token.foreground : .clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t == 0 ? "timer off" : "\(t) second timer")
                        .accessibilityAddTraits(state.timer == t ? .isSelected : [])
                    }
                }
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
                Spacer()
                Text(hint).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground).lineLimit(1)
            }
            shutterButton
        }
        .padding(.horizontal, Token.gutter)
        .padding(.vertical, 10)
        .background(floating ? Color.black.opacity(0.6) : Token.background)
        .overlay(alignment: .top) { if !floating { Rectangle().fill(Token.border).frame(height: Token.rule) } }
        .transaction { $0.animation = nil }
        .onAppear(perform: updateRoute)
        .onChange(of: ble.canShutter) { _, _ in updateRoute() }
        .onChange(of: wifi.isLive) { _, _ in updateRoute() }
    }

    private var shutterButton: some View {
        let lit = state.press != .idle
        return ZStack {
            Rectangle().fill(state.route == .none ? Token.muted : Token.signal)
            if case .half = state.press {
                Rectangle().strokeBorder(Token.ink, lineWidth: 3).padding(5)
            }
            label
                .font(Typeface.medium(17))
                .foregroundStyle(state.route == .none ? Token.mutedForeground : Token.ink)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .overlay(Rectangle().strokeBorder(lit ? Token.foreground : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if state.press == .idle, !cancelled { down() }
                    let d = hypot(v.translation.width, v.translation.height)
                    if d > Self.cancelDistance, !cancelled { cancel() }
                }
                .onEnded { _ in up() }
        )
        .accessibilityElement()
        .accessibilityLabel("shutter")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tapFire() }
    }

    @ViewBuilder private var label: some View {
        switch state.press {
        case .idle:
            Text(state.route == .none ? "no camera" : (state.timer > 0 ? "shutter · \(state.timer)s" : "shutter"))
        case .half:
            Text("focusing · let go to fire")
        case let .bulb(start):
            TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                Text(String(format: "bulb · %.1f s", ctx.date.timeIntervalSince(start)))
                    .monospacedDigit()
            }
        case let .countdown(n):
            Text("\(n)").font(Typeface.display(28))
        case .firing:
            Text("exposing")
        }
    }

    private var hint: String {
        if cancelled { return "cancelled" }
        if let b = lastBulb { return String(format: "last bulb %.1f s", b) }
        switch state.route {
        case .bluetooth: return state.timer > 0 ? "tap to start" : "hold for bulb"
        case .wifi: return "tap to fire"
        case .none: return "pair to shoot"
        }
    }

    private var accessibilityValue: String {
        switch state.press {
        case .idle: return state.route.label
        case .half: return "focusing"
        case .bulb: return "bulb open"
        case let .countdown(n): return "\(n)"
        case .firing: return "exposing"
        }
    }

    private func updateRoute() {
        state.route = ble.canShutter ? .bluetooth : (wifi.isLive ? .wifi : .none)
    }

    // Touch down: half-press so the camera focuses while the finger rests.
    private func down() {
        updateRoute()
        guard state.route != .none, countTask == nil else { return }
        cancelled = false
        lastBulb = nil
        state.press = .half
        Haptic.play(.light)
        guard state.route == .bluetooth, state.timer == 0 else { return }
        ble.shutter(.half)
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.bulbAfter * 1e9))
            guard !Task.isCancelled, state.press == .half, !cancelled else { return }
            ble.shutter(.press)
            state.press = .bulb(Date())
            Haptic.play(.heavy)
        }
    }

    private func cancel() {
        holdTask?.cancel(); holdTask = nil
        cancelled = true
        if state.route == .bluetooth, state.press != .idle { ble.shutter(.release) }
        if case let .bulb(start) = state.press { finishBulb(start) }
        state.press = .idle
        Haptic.play(.warning)
    }

    private func up() {
        holdTask?.cancel(); holdTask = nil
        defer { cancelled = false }
        guard !cancelled else { return }
        switch state.press {
        case .half:
            if state.timer > 0 { startCountdown() } else { fire() }
        case let .bulb(start):
            ble.shutter(.release)
            finishBulb(start)
            state.shots += 1
            state.press = .idle
            Haptic.play(.success)
        default:
            break
        }
    }

    private func tapFire() {
        guard state.route != .none, state.press == .idle else { return }
        if state.timer > 0 { startCountdown() } else { fire() }
    }

    private func startCountdown() {
        countTask = Task { @MainActor in
            for n in stride(from: state.timer, to: 0, by: -1) {
                state.press = .countdown(n)
                Haptic.play(.selection)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
            }
            countTask = nil
            if !Task.isCancelled { fire() }
        }
    }

    private func fire() {
        state.press = .firing
        Haptic.play(.heavy)
        Task { @MainActor in
            switch state.route {
            case .bluetooth:
                ble.shutter(.press)
                try? await Task.sleep(nanoseconds: 150_000_000)
                ble.shutter(.release)
            case .wifi:
                await wifi.shutter()
            case .none:
                break
            }
            state.shots += 1
            try? await Task.sleep(nanoseconds: reduceMotion ? 0 : 160_000_000)
            state.press = .idle
        }
    }

    private func finishBulb(_ start: Date) {
        lastBulb = Date().timeIntervalSince(start)
    }
}

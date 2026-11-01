import UIKit
import SwiftUI
import FujiKit

/// The shoot tab, as in the prototype: a geotag strip, a viewfinder that takes the screen, and
/// one row of recipe chip, square shutter and timer. Live view lives inside the viewfinder.
struct ShootView: View {
    @Environment(BLECameraController.self) private var ble
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
                    VStack(spacing: 0) {
                        GeotagStrip()
                        if ble.savedCameraID == nil {
                            PairPanel()
                                .padding(.horizontal, Token.gutter)
                                .padding(.bottom, 14)
                        } else if !ble.isLinked {
                            LinkLostStrip()
                        }
                        Viewfinder(full: false)
                            .padding(.horizontal, Token.gutter)
                            .padding(.bottom, 12)
                    }
                } bottom: {
                    ShutterRow()
                }
            }
        }
        .background(Token.background.ignoresSafeArea())
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

// MARK: Strips

/// `geotag · synced 10:42 · ±4 m ………… frames 0012`
private struct GeotagStrip: View {
    @Environment(BLECameraController.self) private var ble
    @Environment(ShutterState.self) private var shutter

    var body: some View {
        HStack(spacing: 6) {
            Text("geotag").foregroundStyle(Token.mutedForeground)
            Text("·").foregroundStyle(Token.mark)
            Text(geotag).foregroundStyle(ble.isLinked && ble.lastSync != nil ? Token.foreground : Token.mutedForeground)
            Spacer(minLength: 8)
            Text("frames").foregroundStyle(Token.mutedForeground)
            Text(String(format: "%04d", shutter.shots)).foregroundStyle(Token.foreground).monospacedDigit()
        }
        .font(Typeface.body(13))
        .lineLimit(1)
        .padding(.horizontal, Token.gutter)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    private var geotag: String {
        guard ble.savedCameraID != nil else { return "not paired" }
        guard ble.isLinked else { return "paused" }
        guard ble.autoSync else { return "off" }
        guard let t = ble.lastSync else { return "waiting for the camera" }
        let acc = ble.lastSentLocation.map { " · ±\(Int($0.horizontalAccuracy)) m" } ?? ""
        return "synced " + t.formatted(date: .omitted, time: .shortened).lowercased() + acc
    }
}

/// Paired but not in range: the camera is off or asleep. Not a fault.
private struct LinkLostStrip: View {
    @Environment(BLECameraController.self) private var ble

    var body: some View {
        HStack(spacing: 8) {
            switch ble.phase {
            case .connecting: BlinkMark()
            case .scanning: ScanGlyph()
            case .fault: Text("■").foregroundStyle(Token.signal)
            default: Text("■").foregroundStyle(Token.mark)
            }
            Text(text).foregroundStyle(Token.mutedForeground).lineLimit(1)
            Spacer(minLength: 8)
            FXButton("reconnect", .outline, compact: true) { ble.reconnect() }
        }
        .font(Typeface.body(13))
        .padding(.horizontal, Token.gutter)
        .padding(.bottom, 8)
        .feedIn()
    }

    private var text: String {
        switch ble.phase {
        case .connecting: return "reconnecting to the camera"
        case .scanning: return "looking for the camera"
        case .fault: return "link dropped · shutter paused"
        default: return "camera not in range · shutter paused"
        }
    }
}

// MARK: Viewfinder

/// Dashed while asleep, with `□ live view` in the middle. Types the wake log while it connects,
/// then shows frames with the live chips on top.
private struct Viewfinder: View {
    var full: Bool
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(AppNav.self) private var nav
    @AppStorage("thirdsGrid") private var grid = true

    var body: some View {
        ZStack {
            if wifi.isLive || wifi.frame != nil {
                Color.black
                if let f = wifi.frame {
                    Image(uiImage: f).resizable().scaledToFit()
                } else {
                    Text("waiting for frames").systemLabel()
                }
                if grid { ThirdsGrid().stroke(Token.foreground.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
                chips
            } else {
                Rectangle()
                    .strokeBorder(Token.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                content
                    .padding(Token.gutter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var content: some View {
        switch wifi.phase {
        case .idle, .live:
            VStack(spacing: 18) {
                FXButton("□ live view", .outline) { start() }
                Text("the shutter works over bluetooth.\nlive view wakes the camera's wi-fi.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    .multilineTextAlignment(.center)
            }
        case .joining, .connecting:
            VStack(alignment: .leading, spacing: 10) {
                Text("live view · waking").systemLabel()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(wifi.log.suffix(5).enumerated()), id: \.offset) { _, line in
                        TypedText(text: line.lowercased())
                    }
                    BlinkingCursor()
                }
                .font(Typeface.diagram)
                .foregroundStyle(Token.foreground)
                .lineLimit(1)
                FXButton("cancel", .ghost, compact: true, haptic: .selection) { wifi.disconnect() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .fault(msg):
            FaultPanel(title: "live view", message: msg, line: wifi.log.last.map { "> " + $0.lowercased() },
                       action: ("try again", { start() }))
        }
    }

    /// `■ live · 12 fps` on the left; grid, full and off on the right.
    private var chips: some View {
        VStack {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("■")
                    Text(String(format: "live · %.0f fps", wifi.fps)).monospacedDigit()
                }
                .chip(lit: false)
                Spacer()
                Button { grid.toggle(); Haptic.play(.selection) } label: { Text("#").chip(lit: grid) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("thirds grid")
                    .accessibilityValue(grid ? "on" : "off")
                Button {
                    Haptic.play(.selection)
                    nav.cut { nav.chromeHidden = !full }
                } label: { Text(full ? "exit" : "full").chip(lit: false) }
                    .buttonStyle(.plain)
                Button { Haptic.play(.light); wifi.disconnect() } label: { Text("off").chip(lit: false) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("stop live view")
            }
            Spacer()
        }
        .padding(8)
    }

    private func start() {
        Haptic.play(.light)
        Task { await wifi.connect(joinNetwork: true) }
    }
}

private extension View {
    func chip(lit: Bool) -> some View {
        font(Typeface.body(12))
            .foregroundStyle(lit ? Token.ink : Token.foreground)
            .padding(.horizontal, 9)
            .frame(minWidth: 32, minHeight: 32)
            .background(lit ? Token.foreground : Token.background.opacity(0.8))
            .overlay(Rectangle().strokeBorder(Token.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Live view edge to edge, with the shutter row over it. Chrome comes back when it stops.
private struct FullBleed: View {
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(AppNav.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            Viewfinder(full: true)
            ShutterRow(floating: true)
        }
        .background(Color.black.ignoresSafeArea())
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

// MARK: Shutter

/// Shots and route survive leaving the tab and going full screen.
@MainActor
@Observable
final class ShutterState {
    enum Route: Equatable { case bluetooth, wifi, none }
    enum Press: Equatable { case idle, half, bulb(Date), countdown(Int), firing }

    var shots = 0
    var press: Press = .idle
    var timer = 0
    var route: Route = .none
}

/// `[c3 · in camera / kodachrome 64]   [ fire ]   [timer / off]`, and the hint under it.
private struct ShutterRow: View {
    var floating = false
    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(ShutterState.self) private var state
    @State private var sending: Recipe?
    @State private var lastBulb: Double?
    @State private var cancelled = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                recipeChip.frame(maxWidth: .infinity, alignment: .leading)
                ShutterButton(cancelled: $cancelled, lastBulb: $lastBulb)
                timerChip.frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(hint)
                .systemLabel()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transaction { $0.animation = nil }
        }
        .padding(.horizontal, Token.gutter)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(floating ? Color.black.opacity(0.7) : Token.background)
        .fxSheet(item: $sending, title: { _ in "send to camera" }, meta: { $0.name.lowercased() }) { r in
            SendSheet(recipe: r)
        }
    }

    /// The recipe you're shooting with: the newest one in the camera, else the newest one.
    private var featured: Recipe? {
        store.sorted.first { !store.slots(for: $0).isEmpty } ?? store.sorted.first
    }

    @ViewBuilder private var recipeChip: some View {
        if let r = featured {
            let slots = store.slots(for: r)
            let queued = queue.queuedSlot(for: r)
            let place = slots.first.map { "c\($0) · in camera" } ?? queued.map { "c\($0) · queued" } ?? "library only"
            Button { sending = r; Haptic.play(.selection) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place).systemLabel()
                    Text(r.name.lowercased()).font(Typeface.body(13)).foregroundStyle(Token.foreground)
                }
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: 132, minHeight: 52, alignment: .leading)
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(r.name), \(place). opens the slot grid")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var timerChip: some View {
        Button {
            state.timer = state.timer == 0 ? 2 : (state.timer == 2 ? 10 : 0)
            Haptic.play(.selection)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("timer").systemLabel()
                Text(state.timer == 0 ? "off" : "\(state.timer)s").font(Typeface.body(13)).foregroundStyle(Token.foreground)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(minWidth: 60, minHeight: 52, alignment: .leading)
            .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
        .accessibilityLabel("timer")
        .accessibilityValue(state.timer == 0 ? "off" : "\(state.timer) seconds")
    }

    private var hint: String {
        if cancelled { return "cancelled" }
        switch state.press {
        case .half: return "focusing · release to fire · keep holding for bulb"
        case .bulb: return "bulb open · release to close"
        case .countdown: return "timer running"
        case .firing: return "exposing"
        case .idle: break
        }
        if let b = lastBulb { return String(format: "last bulb %.1f s", b) }
        switch state.route {
        case .bluetooth:
            return state.timer > 0 ? "tap to start the \(state.timer) s timer" : "hold to focus · release to fire · keep holding for bulb"
        case .wifi: return "tap to fire over wi-fi"
        case .none: return "pair the camera to shoot"
        }
    }
}

/// The 88 pt signal square. Touch down half-presses (focus), release fires. Hold past 1.1 s
/// for bulb: the shutter stays open until you let go. Slide off to cancel. The self-timer
/// counts down after release.
private struct ShutterButton: View {
    @Binding var cancelled: Bool
    @Binding var lastBulb: Double?
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(ShutterState.self) private var state
    @State private var holdTask: Task<Void, Never>?
    @State private var countTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bulbAfter = 1.1
    private static let cancelDistance: CGFloat = 24
    private static let side: CGFloat = 88

    var body: some View {
        ZStack {
            Rectangle().fill(state.route == .none ? Token.muted : Token.signal)
            if state.press == .half {
                Rectangle().strokeBorder(Token.ink, lineWidth: 3).padding(6)
            }
            if state.press == .firing {
                Rectangle().fill(Token.foreground)
            }
            label
                .font(Typeface.medium(14))
                .foregroundStyle(state.route == .none ? Token.mutedForeground : Token.ink)
                .multilineTextAlignment(.center)
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .transaction { $0.animation = nil }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if state.press == .idle, !cancelled { down() }
                    if hypot(v.translation.width, v.translation.height) > Self.cancelDistance, !cancelled { cancel() }
                }
                .onEnded { _ in up() }
        )
        .accessibilityElement()
        .accessibilityLabel("shutter")
        .accessibilityIdentifier("shutter")
        .accessibilityHint("hold to focus, release to fire, keep holding for bulb")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tapFire() }
        .onAppear(perform: updateRoute)
        .onChange(of: ble.isLinked) { _, _ in updateRoute() }
        .onChange(of: wifi.isLive) { _, _ in updateRoute() }
    }

    @ViewBuilder private var label: some View {
        switch state.press {
        case .idle: Text(state.route == .none ? "no\ncamera" : "fire")
        case .half: Text("focus")
        case let .bulb(start):
            TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                Text(String(format: "bulb\n%.1f s", ctx.date.timeIntervalSince(start))).monospacedDigit()
            }
        case let .countdown(n): Text("\(n)").font(Typeface.display(34))
        case .firing: Text("")
        }
    }

    private func updateRoute() {
        state.route = ble.canShutter ? .bluetooth : (wifi.isLive ? .wifi : .none)
    }

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
        if case let .bulb(start) = state.press { lastBulb = Date().timeIntervalSince(start) }
        state.press = .idle
        Haptic.play(.warning)
    }

    private func up() {
        holdTask?.cancel(); holdTask = nil
        guard !cancelled else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                cancelled = false
            }
            return
        }
        switch state.press {
        case .half:
            if state.timer > 0 { startCountdown() } else { fire() }
        case let .bulb(start):
            ble.shutter(.release)
            lastBulb = Date().timeIntervalSince(start)
            state.shots += 1
            state.press = .idle
            Haptic.play(.success)
        default:
            break
        }
    }

    private func tapFire() {
        updateRoute()
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

    /// Fill flashes bone for one frame, then the shot counts.
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
            if !reduceMotion { try? await Task.sleep(nanoseconds: 80_000_000) }
            state.press = .idle
        }
    }
}

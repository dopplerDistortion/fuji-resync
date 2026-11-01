import SwiftUI
import FujiKit

// MARK: Tab bar

/// The terminal tab bar: a 1 px top rule, lowercase labels, `■` under the current tab.
/// Tab switches are hard cuts; the label glitches.
struct TabBar: View {
    @Binding var selection: AppTab
    var badge: Int
    @State private var taps: [AppTab: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { t in
                Button {
                    taps[t, default: 0] += 1
                    var tr = Transaction(); tr.disablesAnimations = true
                    withTransaction(tr) { selection = t }
                } label: {
                    VStack(spacing: 5) {
                        GlitchText(text: t.rawValue, trigger: taps[t, default: 0])
                            .font(Typeface.body(13))
                            .foregroundStyle(selection == t ? Token.foreground : Token.mutedForeground)
                        Text("■").font(.system(size: 7)).foregroundStyle(Token.foreground)
                            .opacity(selection == t ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(alignment: .top) {
                        if t == .camera, badge > 0 {
                            Text("\(badge)")
                                .font(Typeface.medium(10))
                                .frame(minWidth: 16, minHeight: 16)
                                .overlay(Rectangle().strokeBorder(Token.foreground, lineWidth: 1))
                                .offset(x: 38, y: 4)
                                .accessibilityLabel("\(badge) queued")
                                .accessibilityIdentifier("tab.badge")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == t ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("tab.\(t.rawValue)")
            }
        }
        .background(Token.background)
        .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: Token.rule) }
    }
}

// MARK: Screen scaffold

/// A tab's screen: the path bar, the content, and an optional pinned bottom bar.
struct TabScreen<Content: View, Trailing: View, Bottom: View>: View {
    var path: [String]
    var onPath: (Int) -> Void = { _ in }
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            PathBar(segments: path, onSegment: onPath) { trailing }
            content.frame(maxHeight: .infinity, alignment: .top)
            bottom
        }
        .background(Token.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension TabScreen where Trailing == LinkMark {
    init(path: [String], onPath: @escaping (Int) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom) {
        self.path = path; self.onPath = onPath
        self.trailing = LinkMark()
        self.content = content(); self.bottom = bottom()
    }
}

extension TabScreen where Trailing == LinkMark, Bottom == EmptyView {
    init(path: [String], onPath: @escaping (Int) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.path = path; self.onPath = onPath
        self.trailing = LinkMark()
        self.content = content(); self.bottom = EmptyView()
    }
}

// MARK: Link mark

/// `■ x-t30 ii` in every path bar: the one camera link and its state. Tap for what rides on it.
struct LinkMark: View {
    @Environment(BLECameraController.self) private var ble
    @State private var open = false
    @State private var changes = 0

    var body: some View {
        let (state, text) = status
        Button { open = true; Haptic.play(.selection) } label: {
            HStack(spacing: 6) {
                switch state {
                case .busy: BlinkMark()
                case .live: Text("■").foregroundStyle(Token.foreground).accessibilityHidden(true)
                case .fault: Text("■").foregroundStyle(Token.signal).accessibilityHidden(true)
                case .idle: Text("■").foregroundStyle(Token.mark).accessibilityHidden(true)
                }
                GlitchText(text: text, trigger: changes)
                    .foregroundStyle(state == .idle ? Token.mutedForeground : Token.foreground)
            }
            .font(Typeface.body(12))
            .lineLimit(1)
            .frame(minHeight: 44)
            .padding(.leading, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("camera link: \(text)")
        .onChange(of: text) { _, _ in changes += 1 }
        .fxSheet(isPresented: $open, title: "x-t30 ii", meta: text) { LinkSheet { open = false } }
    }

    private var status: (StatusMark.State, String) {
        switch ble.phase {
        case let .linked(n): return (.live, n.lowercased())
        case .connecting, .scanning: return (.busy, "linking")
        case .idle: return (.idle, ble.savedCameraID == nil ? "no camera" : "not in range")
        case .off: return (.fault, "bluetooth off")
        case .unauthorized: return (.fault, "no bluetooth")
        case .fault: return (.fault, "link fault")
        }
    }
}

/// What rides on the link right now.
struct LinkSheet: View {
    var close: () -> Void
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(USBCameraController.self) private var usb
    @Environment(SendQueue.self) private var queue
    @Environment(AppNav.self) private var nav
    @Environment(Overlays.self) private var overlays

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("riding on the link right now").systemLabel().padding(.horizontal, Token.gutter)
                VStack(spacing: 0) {
                    row("geotag", geotag, 0)
                    row("shutter", ble.canShutter ? "bluetooth · ready" : (wifi.isLive ? "wi-fi" : "paused"), 1)
                    row("live view", wifi.isLive ? String(format: "wi-fi · %.0f fps", wifi.fps) : "asleep", 2)
                    row("queue", queue.open.isEmpty ? "empty" : "\(queue.open.count) waiting for cable", 3)
                    row("usb-c", usb.isReady ? "ptp ready" : "no cable", 4)
                }
                .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: 1) }
                HStack(spacing: 8) {
                    FXButton("open camera tab", grow: true) {
                        close()
                        nav.cut { nav.tab = .camera }
                    }
                    if ble.isLinked {
                        FXButton("sync now", .outline) {
                            ble.syncNow()
                            Haptic.play(.success)
                            overlays.toast("geotag sent")
                        }
                    }
                }
                .padding(.horizontal, Token.gutter)
            }
        }
    }

    private var geotag: String {
        guard ble.isLinked else { return ble.savedCameraID == nil ? "not paired" : "paused" }
        guard let t = ble.lastSync else { return "waiting for the camera" }
        let acc = ble.lastSentLocation.map { " · ±\(Int($0.horizontalAccuracy)) m" } ?? ""
        return "synced " + t.formatted(date: .omitted, time: .shortened).lowercased() + acc
    }

    private func row(_ label: String, _ value: String, _ i: Int) -> some View {
        LeaderRow(label: label, value: value)
            .padding(.horizontal, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Token.border).frame(height: 1) }
            .stepIn(i)
    }
}

// MARK: Pairing

/// Scan, pick the camera, pair. Used on first launch and in the camera tab.
struct PairPanel: View {
    @Environment(BLECameraController.self) private var ble

    var body: some View {
        Panel(title: "pair camera", meta: "once") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "on the camera: menu › network/usb setting › bluetooth settings › pairing registration.")
                    step(2, "keep it on that screen. resync is listening.")
                }
                HStack(spacing: 10) {
                    switch ble.phase {
                    case .scanning:
                        ScanGlyph()
                        Text("scanning for fujifilm").foregroundStyle(Token.mutedForeground)
                        BlinkingCursor()
                    case let .connecting(n):
                        BlinkMark()
                        Text("pairing \(n.lowercased())")
                    case .off:
                        StatusMark(state: .fault, text: "bluetooth is off")
                    case .unauthorized:
                        StatusMark(state: .fault, text: "bluetooth not allowed for resync")
                    default:
                        FXButton("scan", compact: true) { ble.scan() }
                        if ble.savedCameraID != nil {
                            FXButton("reconnect", .outline, compact: true) { ble.reconnect() }
                        }
                    }
                }
                .font(Typeface.body(13))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !ble.discovered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(ble.discovered.enumerated()), id: \.element.id) { i, d in
                        SelectRow(title: d.name.lowercased(), subtitle: "fujifilm · \(d.rssi) dbm", meta: "pair") {
                            Haptic.play(.light)
                            ble.pair(d)
                        }
                        .feedIn()
                        .stepIn(i)
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: 1) }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").foregroundStyle(Token.mutedForeground)
            Text(text).foregroundStyle(Token.foreground).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.body(13))
    }
}

// MARK: First launch

/// The Boot log types once per install, the name dissolves in, then pairing.
struct BootView: View {
    var done: (AppTab) -> Void
    @Environment(BLECameraController.self) private var ble
    @Environment(RecipeStore.self) private var store
    @State private var bootFinished = false
    @State private var explainedLocation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BootLog(lines: [
                    Motion.dots("mount /recipes", "\(store.recipes.count) entries", width: 26),
                    Motion.dots("probe bluetooth le", ble.phase == .off ? "off" : "on", width: 26),
                    Motion.dots("probe usb-c ptp", "no cable", width: 26),
                    Motion.dots("probe wi-fi", "asleep", width: 26),
                    "ready.",
                ])
                if bootFinished {
                    VStack(alignment: .leading, spacing: 8) {
                        DissolveTitle(text: "resync", size: 52)
                        Text("companion for the fujifilm x-t30 ii.")
                            .font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                    }
                    if ble.isLinked {
                        locationPanel.feedIn()
                    } else {
                        PairPanel()
                    }
                    FXButton("skip · recipes only", .ghost, haptic: .selection) { done(.recipes) }
                }
            }
            .padding(.horizontal, Token.gutter)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.hidden)
        .task {
            try? await Task.sleep(nanoseconds: reduceMotion ? 0 : 1_500_000_000)
            bootFinished = true
            if ble.savedCameraID == nil, ble.phase == .idle { ble.scan() }
        }
        .onChange(of: ble.isLinked) { _, linked in if linked { Haptic.play(.success) } }
    }

    private var locationPanel: some View {
        Panel(title: "location", meta: "for geotags") {
            VStack(alignment: .leading, spacing: 12) {
                Text("the camera asks for your location each time it saves a photo. resync answers in the background, so pick always allow on the next prompt.")
                    .font(Typeface.body(14)).fixedSize(horizontal: false, vertical: true)
                FXButton(explainedLocation ? "open the shoot tab" : "continue", grow: true) {
                    if explainedLocation {
                        done(.shoot)
                    } else {
                        ble.location.requestPermission()
                        explainedLocation = true
                    }
                }
            }
            .padding(14)
        }
    }
}

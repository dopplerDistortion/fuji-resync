import SwiftUI

/// The log tab: what the app did with the camera, the few settings there are, and credits.
struct LogView: View {
    @Environment(BLECameraController.self) private var ble
    @Environment(Overlays.self) private var overlays
    @AppStorage("haptics") private var haptics = true
    @AppStorage("wifiIdleMinutes") private var wifiIdle = 5
    @State private var lines: [String] = []
    @State private var category: String = "all"

    private static let categories = ["all", "ble", "usb", "wifi", "recipes", "store", "app"]

    var body: some View {
        TabScreen(path: ["log"]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Panel(title: "settings") {
                        VStack(spacing: 0) {
                            Toggle("haptics", isOn: $haptics).toggleStyle(.fx).accessibilityIdentifier("setting.haptics")
                            Toggle("geotag photos", isOn: Binding(get: { ble.autoSync }, set: { ble.autoSync = $0 })).toggleStyle(.fx).accessibilityIdentifier("setting.geotag")
                            Segmented(label: "wi-fi idle", selection: $wifiIdle, options: [1, 5, 15]) { "\($0) min" }
                        }
                    }
                    BLEBackupTestPanel()
                    ProPanel()
                    tail
                    about
                }
                .padding(.horizontal, Token.gutter)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        } bottom: {
            BottomBar {
                FXButton("share log", grow: true) { ShareSheet.present([AppLog.fileURL]) }
                FXButton("clear", .ghost, haptic: .selection) {
                    overlays.confirm("clear the log?", message: "the log is how a bug report shows what happened. share it first if something went wrong.", confirm: "clear") {
                        AppLog.clear()
                        lines = []
                        AppLog.write(.app, "log cleared")
                    }
                }
            }
        }
        .task {
            // Tail the file while the tab is open.
            while !Task.isCancelled {
                load()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var shown: [String] {
        guard category != "all" else { return lines }
        return lines.filter { $0.contains("[\(category)]") }
    }

    private var tail: some View {
        Panel(title: "tail resync.log", meta: "\(shown.count) lines") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Self.categories, id: \.self) { c in
                            Button {
                                category = c
                                Haptic.play(.selection)
                            } label: {
                                Text(c)
                                    .font(Typeface.body(12))
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 32)
                                    .foregroundStyle(category == c ? Token.ink : Token.foreground)
                                    .background(category == c ? Token.foreground : .clear)
                                    .overlay(Rectangle().strokeBorder(category == c ? Token.foreground : Token.input, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(category == c ? .isSelected : [])
                        }
                    }
                }
                .transaction { $0.animation = nil }
                if shown.isEmpty {
                    Text("> nothing logged yet").font(Typeface.diagram).foregroundStyle(Token.mutedForeground)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(shown.suffix(60).enumerated()), id: \.offset) { _, line in
                            LogLine(line: line)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel(title: "about", meta: version) {
                Text("a personal companion for the fujifilm x-t30 ii. recipes go over usb-c, location and the shutter over bluetooth, live view over wi-fi.")
                    .font(Typeface.body(14)).fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
            Panel(title: "credits", meta: "mit") {
                VStack(spacing: 0) {
                    ForEach(["eggricesoy/filmkit", "petabyt/libfuji", "gkoh/furble", "hkr/fuji-cam-wifi-tool"], id: \.self) { name in
                        LeaderRow(label: name, value: credit(name))
                    }
                }
            }
            Panel(title: "fonts", meta: "ofl") {
                VStack(spacing: 0) {
                    LeaderRow(label: "martian mono", value: "display")
                    LeaderRow(label: "geist mono", value: "body")
                }
            }
            Text("not affiliated with fujifilm. writing custom settings uses an undocumented protocol: keep the camera on and the cable in until it finishes.")
                .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func credit(_ name: String) -> String {
        switch name {
        case "eggricesoy/filmkit": return "custom settings"
        case "petabyt/libfuji": return "wi-fi remote"
        case "gkoh/furble": return "bluetooth"
        default: return "early wi-fi work"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "v" + (info?["CFBundleShortVersionString"] as? String ?? "?")
    }

    private func load() {
        let all = AppLog.contents().split(separator: "\n", omittingEmptySubsequences: true)
        lines = all.suffix(400).map(String.init)
    }
}

/// `10:31:02 ble  geotag sent ±8 m`: time, category, message. Faults in red.
private struct LogLine: View {
    var line: String

    var body: some View {
        let (time, cat, msg) = parts
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).foregroundStyle(Token.mark)
            Text(cat).foregroundStyle(Token.mutedForeground).frame(width: 44, alignment: .leading)
            Text(msg).foregroundStyle(isFault ? Token.signal : Token.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.diagram)
    }

    private var isFault: Bool {
        let l = line.lowercased()
        return l.contains("fault") || l.contains("failed") || l.contains("rejected")
    }

    /// Lines are `<iso8601> [category] message`.
    private var parts: (String, String, String) {
        guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close else { return ("", "", line) }
        let stamp = line[..<open].trimmingCharacters(in: .whitespaces)
        let time: String
        if let t = stamp.firstIndex(of: "T") {
            time = String(stamp[stamp.index(after: t)...].prefix(8))
        } else {
            time = String(stamp.prefix(8))
        }
        let cat = String(line[line.index(after: open) ..< close])
        let msg = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (time, cat, msg)
    }
}

/// T1 from the recipes requirements: a read-only download of the camera's settings backup over
/// Bluetooth, to see whether the X-T30 II answers XApp's sequence at all. Saves the raw file to share.
private struct BLEBackupTestPanel: View {
    @Environment(BLECameraController.self) private var ble

    var body: some View {
        Panel(title: "bluetooth backup test", meta: "read only") {
            VStack(alignment: .leading, spacing: 12) {
                Text("asks the camera for a copy of its settings (backup.dat) over bluetooth and saves it. nothing on the camera changes. keep the camera on and out of its menus.")
                    .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                status
                FXButton(ble.backupRunning ? "reading…" : "read backup.dat", .signal, grow: true, haptic: .medium) {
                    Task { await ble.runBackupTest() }
                }
                .disabled(ble.backupRunning || !ble.isLinked)
                .accessibilityIdentifier("ble.backupTest")
                if !ble.isLinked {
                    Text("connect the camera over bluetooth first.").font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private var status: some View {
        switch ble.backupTest {
        case .idle:
            EmptyView()
        case let .running(step):
            HStack(spacing: 8) {
                BlinkMark()
                Text(step).font(Typeface.body(13))
            }
        case let .failed(message):
            Text(message).font(Typeface.body(13)).foregroundStyle(Token.signal)
                .fixedSize(horizontal: false, vertical: true)
            FXButton("share gatt list + log", .outline, compact: true) { share(nil) }
        case let .done(r):
            VStack(spacing: 0) {
                LeaderRow(label: r.name, value: "\(r.bytes) bytes")
                LeaderRow(label: "pieces", value: "\(r.pieces)")
                LeaderRow(label: "checksum", value: r.checksumOK.map { $0 ? "ok" : "mismatch" } ?? "none sent")
            }
            FXButton("share backup + gatt list", .outline, compact: true) { share(r) }
        }
    }

    private func share(_ r: BLECameraController.BackupResult?) {
        var items: [Any] = []
        if let r { items += [r.file, r.inventory] } else if let url = ShareSheet.file(Data(ble.gattInventory().utf8), name: "resync gatt.txt") { items.append(url) }
        items.append(AppLog.fileURL)
        ShareSheet.present(items)
    }
}

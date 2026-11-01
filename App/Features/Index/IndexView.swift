import SwiftUI
import FujiKit

enum Route: Hashable {
    case recipes
    case recipe(UUID)
    case newRecipe
    case camera
    case sync
    case remote
    case about
}

/// Home: identity card, a one-time boot log, and the index listing.
struct IndexView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(USBCameraController.self) private var usb
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @SceneStorage("booted") private var booted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bootLines: [String] = []

    private let boot = [
        "mount /recipes ............ ok",
        "probe usb-c ptp ........... ok",
        "probe bluetooth le ........ ok",
        "probe wi-fi 192.168.0.1 ... ok",
        "ready",
    ]

    var body: some View {
        Screen(path: [], title: "resync", subtitle: "companion for the fujifilm x-t30 ii.") {
            if !booted || !bootLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bootLines, id: \.self) { Text($0) }
                }
                .font(Typeface.diagram)
                .foregroundStyle(Token.mutedForeground)
                .task { await runBoot() }
            }

            VStack(alignment: .leading, spacing: 12) {
                ListingHeader(path: "/", count: 5)
                NavigationLink(value: Route.recipes) {
                    LeaderRow(mark: "1", label: "recipes", value: "\(store.recipes.count)")
                }
                NavigationLink(value: Route.camera) {
                    LeaderRow(mark: "2", label: "camera · usb", value: usbStatus, valueColor: usb.isReady ? Token.foreground : Token.mutedForeground)
                }
                NavigationLink(value: Route.sync) {
                    LeaderRow(mark: "3", label: "sync · gps", value: bleStatus, valueColor: ble.isLinked ? Token.foreground : Token.mutedForeground)
                }
                NavigationLink(value: Route.remote) {
                    LeaderRow(mark: "4", label: "remote · wi-fi", value: wifi.isLive ? "live" : "off", valueColor: wifi.isLive ? Token.signal : Token.mutedForeground)
                }
                NavigationLink(value: Route.about) {
                    LeaderRow(mark: "5", label: "about", value: "")
                }
            }
            .buttonStyle(.plain)

            Panel(title: "recent", meta: "/recipes") {
                ForEach(store.sorted.prefix(3)) { r in
                    NavigationLink(value: Route.recipe(r.id)) {
                        LeaderRow(label: r.name.lowercased(), value: r.filmSimulation.label.lowercased())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var usbStatus: String {
        switch usb.phase {
        case .ready: return "ready"
        case .searching, .opening: return "waiting"
        case .fault: return "fault"
        default: return "off"
        }
    }

    private var bleStatus: String {
        if ble.isLinked { return ble.lastSync.map { "synced " + $0.formatted(date: .omitted, time: .shortened) } ?? "linked" }
        return ble.savedCameraID == nil ? "not paired" : "out of range"
    }

    private func runBoot() async {
        guard !booted else { return }
        if reduceMotion { bootLines = boot; booted = true; return }
        for line in boot {
            bootLines.append(line)
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        booted = true
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(.easeOut(duration: 0.2)) { bootLines = [] }
    }
}

struct AboutView: View {
    var body: some View {
        Screen(path: ["about"], title: "about") {
            Panel(title: "resync") {
                Text("a personal companion for the fujifilm x-t30 ii. recipes go over usb-c, location over bluetooth, live view over wi-fi.")
                    .font(Typeface.body(14)).foregroundStyle(Token.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Panel(title: "credits", meta: "mit") {
                ForEach(["eggricesoy/filmkit — custom-setting properties", "petabyt/libfuji — wi-fi remote", "gkoh/furble — bluetooth geotag and shutter", "hkr/fuji-cam-wifi-tool — early wi-fi work"], id: \.self) {
                    LeaderRow(label: $0, value: "")
                }
            }
            Panel(title: "fonts", meta: "ofl") {
                LeaderRow(label: "martian mono", value: "display")
                LeaderRow(label: "geist mono", value: "body")
            }
            Panel(title: "logs", meta: "documents/resync.log") {
                Text("everything the app does with the camera is written here. share it when something goes wrong.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ShareLink(item: AppLog.fileURL) { Text("share log") }
                        .buttonStyle(.fx(.default, compact: true))
                    Button("clear") { AppLog.clear() }.buttonStyle(.fx(.ghost))
                }
            }
            Text("not affiliated with fujifilm. writing custom settings uses an undocumented protocol: keep the camera powered and the cable in until it finishes.")
                .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
        }
    }
}

import UIKit
import SwiftUI
import FujiKit

@main
struct ResyncApp: App {
    @State private var store = RecipeStore(filename: UITest.storeFilename())
    @State private var usb = USBCameraController()
    @State private var ble = BLECameraController()
    @State private var wifi = WiFiRemoteController()
    @State private var queue = SendQueue()
    @State private var overlays = Overlays()
    @State private var nav = AppNav()
    @State private var shutter = ShutterState()
    @State private var session = ShootingSession()
    @State private var places = PhotoPlaces(filename: UITest.isOn ? "uitest-photo-places.json" : "photo-places.json")

    init() {
        AppLog.session()
        // The app draws its own path bar, tab bar and overlays. The file picker and the share
        // sheet are Apple's; give their bars the system's ink and type.
        let label = UIFont(name: "GeistMono-Medium", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Token.background)
        nav.shadowColor = UIColor(Token.border)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Token.foreground), .font: label]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Token.foreground)
        // Text cursors in the system's ink.
        UITextField.appearance().tintColor = UIColor(Token.foreground)
        UITextView.appearance().tintColor = UIColor(Token.foreground)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(usb)
                .environment(ble)
                .environment(wifi)
                .environment(queue)
                .environment(overlays)
                .environment(nav)
                .environment(shutter)
                .environment(session)
                .environment(places)
                .preferredColorScheme(.dark)
                .tint(Token.foreground)
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case shoot, recipes, camera, log
    var id: String { rawValue }
}

enum RecipeRoute: Hashable {
    case edit(UUID)
    case new(UUID)
}

/// Navigation state the tabs share: the selected tab, the recipes stack, and whether the
/// chrome (path bar and tab bar) is hidden for full-bleed live view.
@MainActor
@Observable
final class AppNav {
    var tab: AppTab = .recipes
    var recipes: [RecipeRoute] = []
    /// The library's search and filter, kept while a recipe is open.
    var recipeQuery = ""
    var recipeFilter = "all"
    var chromeHidden = false

    /// Pushes or pops with a hard cut, not a slide.
    func cut(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }

    func open(_ id: UUID) {
        cut {
            tab = .recipes
            recipes = [.edit(id)]
        }
    }
}

struct RootView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(USBCameraController.self) private var usb
    @Environment(BLECameraController.self) private var ble
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(SendQueue.self) private var queue
    @Environment(Overlays.self) private var overlays
    @Environment(AppNav.self) private var nav
    @Environment(ShootingSession.self) private var session
    @Environment(ShutterState.self) private var shutter
    @Environment(PhotoPlaces.self) private var places
    @AppStorage("booted") private var booted = false
    @AppStorage("wifiIdleMinutes") private var wifiIdleMinutes = 5
    @SceneStorage("tab") private var savedTab: String?
    @State private var idleTask: Task<Void, Never>?
    @State private var keyboardUp = false

    var body: some View {
        @Bindable var nav = nav
        Group {
            if booted {
                VStack(spacing: 0) {
                    // Only the current tab is built; a switch is a hard cut.
                    Group {
                        switch nav.tab {
                        case .shoot: ShootView()
                        case .recipes: RecipesTab()
                        case .camera: CameraView()
                        case .log: LogView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { OverlayHost(bottomInset: nav.chromeHidden ? 120 : 74) }
                    if !nav.chromeHidden, !keyboardUp {
                        TabBar(selection: $nav.tab, badge: queue.open.count)
                    }
                }
            } else {
                BootView { tab in
                    booted = true
                    nav.tab = tab
                }
                .overlay { OverlayHost(bottomInset: 24) }
            }
        }
        .overlay { MenuLayer() }
        .background(Token.background.ignoresSafeArea())
        .font(Typeface.body())
        .foregroundStyle(Token.foreground)
        .transaction { $0.animation = nil }
        .onAppear(perform: restore)
        // The keyboard covers the tab bar's place; the screen's own bottom bar rides on top of it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        // Every USB read (and the read-back after a write) refreshes the "in camera" marks.
        .onChange(of: usb.slots) { _, slots in store.updateCamera(slots) }
        // The queue drains the moment a camera is ready on USB.
        .onChange(of: usb.isReady) { _, ready in if ready { drain() } }
        .onChange(of: queue.kick) { _, _ in
            if usb.isReady { drain() } else { usb.start() }
        }
        .onChange(of: nav.tab) { old, new in
            savedTab = new.rawValue
            Haptic.play(.selection)
            if new != .shoot { nav.chromeHidden = false }
            scheduleWiFiIdle(leaving: old, to: new)
        }
    }

    private func restore() {
        ble.onGeotag = { [places] loc in places.record(loc) }
        #if DEBUG
        if UITest.isOn {
            store.seedCameraForUITests()
            places.seedForUITests()
            nav.tab = .recipes
            return
        }
        #endif
        session.restore(ble: ble, shutter: shutter)
        // Existing installs that already paired skip the first-launch boot.
        if !booted, ble.savedCameraID != nil { booted = true }
        if let s = savedTab, let t = AppTab(rawValue: s) { nav.tab = t } else { nav.tab = ble.savedCameraID != nil ? .shoot : .recipes }
    }

    private func drain() {
        Task {
            await queue.drain(usb: usb, store: store, overlays: overlays)
            // Then the map's pins: the GPS of every photo on the card not read before.
            let read = await usb.readPhotoPlaces(skipping: places.checked)
            if !read.checked.isEmpty { places.merge(read.places, checked: read.checked) }
        }
    }

    /// Wi-Fi stays up when you leave the shoot tab and drops after the idle setting.
    private func scheduleWiFiIdle(leaving old: AppTab, to new: AppTab) {
        idleTask?.cancel(); idleTask = nil
        guard new != .shoot, wifi.isLive else { return }
        let minutes = wifiIdleMinutes
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, nav.tab != .shoot, wifi.isLive else { return }
            AppLog.write(.wifi, "live view idle \(minutes) min, closing")
            wifi.disconnect()
        }
    }
}

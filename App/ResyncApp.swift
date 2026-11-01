import UIKit
import SwiftUI
import FujiKit

@main
struct ResyncApp: App {
    @State private var store = RecipeStore()
    @State private var usb = USBCameraController()
    @State private var ble = BLECameraController()
    @State private var wifi = WiFiRemoteController()
    @State private var queue = SendQueue()
    @State private var overlays = Overlays()
    @State private var nav = AppNav()
    @State private var shutter = ShutterState()

    init() {
        AppLog.session()
        // The app draws its own path bar and tab bar; keep any system bar that slips through dark.
        let label = UIFont(name: "GeistMono-Medium", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Token.background)
        nav.shadowColor = UIColor(Token.border)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Token.foreground), .font: label]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Token.foreground)
        // Keyboard toolbar, text selection and switches in the system's ink.
        UIToolbar.appearance().barTintColor = UIColor(Token.card)
        UIToolbar.appearance().tintColor = UIColor(Token.foreground)
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
    @AppStorage("booted") private var booted = false
    @AppStorage("wifiIdleMinutes") private var wifiIdleMinutes = 5
    @SceneStorage("tab") private var savedTab: String?
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        @Bindable var nav = nav
        Group {
            if booted {
                VStack(spacing: 0) {
                    TabView(selection: $nav.tab) {
                        ShootView().tag(AppTab.shoot).toolbar(.hidden, for: .tabBar)
                        RecipesTab().tag(AppTab.recipes).toolbar(.hidden, for: .tabBar)
                        CameraView().tag(AppTab.camera).toolbar(.hidden, for: .tabBar)
                        LogView().tag(AppTab.log).toolbar(.hidden, for: .tabBar)
                    }
                    .overlay { OverlayHost(bottomInset: nav.chromeHidden ? 120 : 74) }
                    if !nav.chromeHidden {
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
        .background(Token.background.ignoresSafeArea())
        .font(Typeface.body())
        .foregroundStyle(Token.foreground)
        .transaction { $0.animation = nil }
        .onAppear(perform: restore)
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
        // Existing installs that already paired skip the first-launch boot.
        if !booted, ble.savedCameraID != nil { booted = true }
        if let s = savedTab, let t = AppTab(rawValue: s) { nav.tab = t } else { nav.tab = ble.savedCameraID != nil ? .shoot : .recipes }
    }

    private func drain() {
        Task { await queue.drain(usb: usb, store: store, overlays: overlays) }
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

// Swipe-back keeps working with the system navigation bar hidden.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

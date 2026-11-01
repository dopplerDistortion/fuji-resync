import UIKit
import SwiftUI
import FujiKit

@main
struct ResyncApp: App {
    @State private var store = RecipeStore()
    @State private var usb = USBCameraController()
    @State private var ble = BLECameraController()
    @State private var wifi = WiFiRemoteController()

    init() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Token.background)
        nav.shadowColor = UIColor(Token.border)
        let label = UIFont(name: "GeistMono-Medium", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .medium)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Token.foreground), .font: label]
        nav.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(Token.foreground), .font: label]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(Token.foreground)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(usb)
                .environment(ble)
                .environment(wifi)
                .preferredColorScheme(.dark)
                .tint(Token.foreground)
        }
    }
}

struct RootView: View {
    @Environment(RecipeStore.self) private var store
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            IndexView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .recipes: RecipeListView()
                    case let .recipe(id):
                        if let r = store.recipe(id) { RecipeEditorView(recipe: r) } else { Text("cd: no such recipe").systemLabel() }
                    case .newRecipe: RecipeEditorView(recipe: Recipe(), isNew: true)
                    case .camera: CameraView()
                    case .sync: SyncView()
                    case .remote: RemoteView()
                    case .about: AboutView()
                    }
                }
        }
        .background(Token.background.ignoresSafeArea())
        .font(Typeface.body())
    }
}

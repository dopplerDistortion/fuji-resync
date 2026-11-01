import UIKit
import SwiftUI
import FujiKit
import UniformTypeIdentifiers

/// The recipes tab: the library list and the editor, pushed with hard cuts.
struct RecipesTab: View {
    @Environment(AppNav.self) private var nav
    @Environment(RecipeStore.self) private var store

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.recipes) {
            RecipeListView()
                .navigationDestination(for: RecipeRoute.self) { route in
                    switch route {
                    case let .edit(id):
                        if let r = store.recipe(id) {
                            RecipeEditorView(recipe: r)
                        } else {
                            GoneView()
                        }
                    case let .new(id):
                        RecipeEditorView(recipe: store.recipe(id) ?? Recipe(id: id, name: "untitled"), isNew: store.recipe(id) == nil)
                    }
                }
        }
    }
}

private struct GoneView: View {
    @Environment(AppNav.self) private var nav

    var body: some View {
        TabScreen(path: ["recipes", "gone"], onPath: { _ in nav.cut { nav.recipes = [] } }) {
            FaultPanel(title: "recipe", message: "this recipe was deleted. go back to the library.",
                       action: ("back to recipes", { nav.cut { nav.recipes = [] } }))
                .padding(Token.gutter)
        }
    }
}

struct RecipeListView: View {
    enum Filter: String, CaseIterable { case all, inCamera = "in camera", library = "library only" }

    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(USBCameraController.self) private var usb
    @Environment(Overlays.self) private var overlays
    @Environment(AppNav.self) private var nav
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var importing = false
    @State private var more = false
    @State private var sending: Recipe?

    private var filtered: [Recipe] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.sorted.filter { r in
            switch filter {
            case .all: break
            case .inCamera: if store.slots(for: r).isEmpty { return false }
            case .library: if !store.slots(for: r).isEmpty { return false }
            }
            guard !q.isEmpty else { return true }
            return r.name.lowercased().contains(q) || r.filmSimulation.label.lowercased().contains(q)
                || r.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private var inCamera: Int { store.recipes.filter { !store.slots(for: $0).isEmpty }.count }

    /// Camera slots whose settings aren't in the library yet, at the last read.
    private var missing: [Int] {
        (store.camera?.slots ?? []).filter { store.libraryMatch(for: $0.recipe) == nil }.map(\.slot)
    }

    var body: some View {
        TabScreen(path: ["recipes"]) {
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets(top: 14, leading: Token.gutter, bottom: 10, trailing: Token.gutter))
                    if !missing.isEmpty || store.camera == nil {
                        pullBar
                            .listRowInsets(EdgeInsets(top: 0, leading: Token.gutter, bottom: 12, trailing: Token.gutter))
                    }
                    if let err = store.lastError {
                        FaultPanel(title: "save", message: err)
                            .listRowInsets(EdgeInsets(top: 0, leading: Token.gutter, bottom: 12, trailing: Token.gutter))
                    }
                    if filtered.isEmpty {
                        Text(store.recipes.isEmpty ? "> no recipes yet. tap new, import a file, or pull c1–c7 from the camera."
                                                   : "> nothing matches. clear the search or the filter.")
                            .font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                            .listRowInsets(EdgeInsets(top: 8, leading: Token.gutter, bottom: 8, trailing: Token.gutter))
                    }
                }
                .listRowBackground(Token.background)
                .listRowSeparator(.hidden)

                Section {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, r in
                        row(r)
                            .stepIn(i)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Token.background)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Token.background)
            .environment(\.defaultMinListRowHeight, 1)
        } bottom: {
            BottomBar {
                FXField(text: $query, prompt: "grep", mark: "/")
                FXButton("new", compact: true) { newRecipe() }
                FXButton("···", .outline, compact: true, haptic: .selection) { more = true }
                    .accessibilityLabel("more")
                    .fxMenu(isPresented: $more, items: menu)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .text], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .fxSheet(item: $sending, title: { _ in "send to camera" }, meta: { $0.name.lowercased() }) { r in
            SendSheet(recipe: r)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListingHeader(path: "/recipes", count: store.recipes.count, extra: "\(inCamera) in camera")
            HStack(spacing: 0) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button {
                        filter = f
                        Haptic.play(.selection)
                    } label: {
                        Text(f.rawValue)
                            .font(Typeface.body(12))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .foregroundStyle(filter == f ? Token.ink : Token.foreground)
                            .background(filter == f ? Token.foreground : .clear)
                            .overlay(Rectangle().strokeBorder(filter == f ? Token.foreground : Token.input, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .transaction { $0.animation = nil }
        }
    }

    /// One action from camera to library. Shown while the camera holds something the library lacks.
    private var pullBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if store.camera == nil {
                    Text("camera never read").font(Typeface.body(13))
                    Text("plug it in once to mark what's in c1–c7").font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                } else {
                    Text(missing.map { "c\($0)" }.joined(separator: " ") + (missing.count == 1 ? " isn't" : " aren't") + " in the library")
                        .font(Typeface.body(13))
                    Text(usb.isReady ? "camera on the cable" : "pulls when the camera is plugged in")
                        .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                }
            }
            Spacer(minLength: 0)
            FXButton(pulling ? "pulling" : "pull c1–c7", .outline, compact: true) { pull() }
                .disabled(pulling)
        }
        .padding(10)
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: 1))
        .feedIn()
    }

    private var pulling: Bool { queue.open.contains { $0.kind == .pull } }

    private func row(_ r: Recipe) -> some View {
        let slots = store.slots(for: r)
        let state: SlotBadge.State = !slots.isEmpty ? .inCamera(slots) : (queue.queuedSlot(for: r).map { .queued($0) } ?? .none)
        return Button {
            nav.cut { nav.recipes.append(.edit(r.id)) }
        } label: {
            EmptyView()
        }
        .buttonStyle(RecipeRowStyle(recipe: r, state: state, unsupported: !r.filmSimulation.onXT30II))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { sending = r } label: { Text("send") }
                .tint(Token.signal)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { delete(r) } label: { Text("delete") }
                .tint(Token.signal)
            Button {
                let copy = store.duplicate(r)
                overlays.toast("duplicated \(r.name.lowercased())", action: "open") { nav.open(copy.id) }
            } label: { Text("copy") }
                .tint(Token.muted)
        }
        .contextMenu {
            Button("send to camera") { sending = r }
            Button("duplicate") { _ = store.duplicate(r) }
            Button("share as text") { ShareSheet.present([RecipeText.format(r)]) }
            Button("delete", role: .destructive) { delete(r) }
        }
    }

    private var menu: [FXMenuItem] {
        [
            FXMenuItem(title: "pull c1–c7 to library", meta: usb.isReady ? "usb" : "queued") { pull() },
            FXMenuItem(title: "import file", meta: ".json .txt") { importing = true },
            FXMenuItem(title: "paste recipe", meta: "clipboard") { paste() },
            FXMenuItem(title: "export json", meta: "\(store.recipes.count)") {
                if let url = ShareSheet.file(store.exportBundle(), name: "recipes.json") { ShareSheet.present([url]) }
            },
            FXMenuItem(title: "export text", meta: "\(store.recipes.count)") { ShareSheet.present([store.exportText()]) },
        ]
    }

    // MARK: Actions

    private func newRecipe() {
        nav.cut { nav.recipes.append(.new(UUID())) }
    }

    private func pull() {
        queue.pull()
        if !usb.isReady { overlays.toast("pull queued", detail: "runs when the camera is on the cable") }
    }

    private func delete(_ r: Recipe) {
        store.delete([r.id])
        Haptic.play(.warning)
        overlays.toast("deleted \(r.name.lowercased())", action: "undo", duration: 5) {
            store.upsert(r)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var total = RecipeStore.ImportResult()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let r = store.importData(data, fallbackName: url.deletingPathExtension().lastPathComponent)
                    total.added += r.added; total.updated += r.updated; total.skipped += r.skipped
                }
            }
            overlays.toast(Self.describe(total, verb: "imported"))
        case let .failure(e):
            Haptic.play(.error)
            overlays.toast("import failed", detail: e.localizedDescription.lowercased())
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            overlays.toast("clipboard is empty", detail: "copy a recipe's text first")
            return
        }
        overlays.toast(Self.describe(store.importData(Data(text.utf8), fallbackName: "pasted"), verb: "pasted"))
    }

    static func describe(_ r: RecipeStore.ImportResult, verb: String) -> String {
        func n(_ c: Int) -> String { "\(c) recipe\(c == 1 ? "" : "s")" }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(verb) \(n(r.added))") }
        if r.updated > 0 { parts.append("updated \(n(r.updated))") }
        if r.skipped > 0 { parts.append("\(r.skipped) already here") }
        return parts.isEmpty ? "nothing to import" : parts.joined(separator: ", ")
    }
}

/// `[C3] classic chrome summer ┄┄ classic chrome >`. Fills bone while pressed.
private struct RecipeRowStyle: ButtonStyle {
    var recipe: Recipe
    var state: SlotBadge.State
    var unsupported: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = configuration.isPressed
        return HStack(spacing: 12) {
            SlotBadge(state: state)
                .inverted(lit)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name.lowercased())
                    .font(Typeface.body(15))
                    .lineLimit(1)
                Text(recipe.filmSimulation.label.lowercased() + (unsupported ? " · not on x-t30 ii" : ""))
                    .font(Typeface.body(12))
                    .foregroundStyle(lit ? Token.ink.opacity(0.7) : (unsupported ? Token.signal : Token.mutedForeground))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(">").foregroundStyle(lit ? Token.ink : Token.mark).accessibilityHidden(true)
        }
        .foregroundStyle(lit ? Token.ink : Token.foreground)
        .padding(.horizontal, Token.gutter)
        .frame(minHeight: 56)
        .background(lit ? Token.foreground : Token.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Token.border).frame(height: 1) }
        .contentShape(Rectangle())
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder func inverted(_ on: Bool) -> some View {
        if on { colorInvert() } else { self }
    }
}

import UIKit
import SwiftUI
import FujiKit
import UniformTypeIdentifiers

/// The recipes tab: the library list and the editor, pushed and popped with hard cuts. A drag
/// from the left edge pulls the editor aside in 8 pt steps over the list, and lets go with
/// a cut either way.
struct RecipesTab: View {
    @Environment(AppNav.self) private var nav
    @Environment(RecipeStore.self) private var store
    @State private var pull: CGFloat = 0

    var body: some View {
        let top = nav.recipes.last
        GeometryReader { g in
            ZStack {
                // The list is only built while it shows: at the root, or under a back swipe.
                // Its search and filter live in AppNav, so they outlast the push.
                if top == nil || pull > 0 {
                    RecipeListView()
                        .allowsHitTesting(top == nil)
                        .accessibilityHidden(top != nil)
                }
                if let top {
                    destination(top)
                        .id(top)
                        .background(Token.background.ignoresSafeArea())
                        .overlay(alignment: .leading) {
                            if pull > 0 { Rectangle().fill(Token.foreground).frame(width: Token.rule).ignoresSafeArea() }
                        }
                        .offset(x: pull)
                        .overlay(alignment: .leading) { edge(width: g.size.width) }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private func destination(_ route: RecipeRoute) -> some View {
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

    /// The strip along the left edge that takes the back swipe.
    private func edge(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { v in pull = max(0, (v.translation.width / 8).rounded(.down) * 8) }
                    .onEnded { v in
                        let back = v.translation.width > width * 0.33 || v.predictedEndTranslation.width > width * 0.6
                        pull = 0
                        if back {
                            Haptic.play(.selection)
                            nav.cut { _ = nav.recipes.popLast() }
                        }
                    }
            )
            .accessibilityHidden(true)
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
    enum Filter: String, CaseIterable { case all, inCamera = "in camera" }

    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(USBCameraController.self) private var usb
    @Environment(Overlays.self) private var overlays
    @Environment(AppNav.self) private var nav
    private var query: String { nav.recipeQuery }
    private var filter: Filter { Filter(rawValue: nav.recipeFilter) ?? .all }
    @State private var gate = SwipeGate()
    @State private var importing = false
    @State private var more = false
    @State private var sending: Recipe?
    @State private var swiped: UUID?
    @State private var rowMenu: UUID?
    @State private var heldRow: UUID?

    private var filtered: [Recipe] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.sorted.filter { r in
            switch filter {
            case .all: break
            case .inCamera: if store.slots(for: r).isEmpty { return false }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, Token.gutter)
                        .padding(.top, 14).padding(.bottom, 10)
                    if !missing.isEmpty || store.camera == nil {
                        pullBar
                            .padding(.horizontal, Token.gutter)
                            .padding(.bottom, 12)
                    }
                    if let err = store.lastError {
                        FaultPanel(title: "save", message: err)
                            .padding(.horizontal, Token.gutter)
                            .padding(.bottom, 12)
                    }
                    if filtered.isEmpty {
                        Text(store.recipes.isEmpty ? "> no recipes yet. tap new, import a file, or pull c1–c7 from the camera."
                                                   : "> nothing matches. clear the search or the filter.")
                            .font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Token.gutter)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, r in
                        row(r).stepIn(i)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
            .background(Token.background)
        } bottom: {
            BottomBar {
                FXField(text: Binding(get: { nav.recipeQuery }, set: { nav.recipeQuery = $0 }), prompt: "grep recipes", mark: "/")
                FXButton("new", compact: true) { newRecipe() }
                FXButton("…", .outline, compact: true, haptic: .selection) { more = true }
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
        VStack(alignment: .leading, spacing: 12) {
            ListingHeader(path: "/recipes", count: store.recipes.count, extra: "\(inCamera) in camera")
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let n = f == .all ? store.recipes.count : inCamera
                    Button {
                        nav.recipeFilter = f.rawValue
                        Haptic.play(.selection)
                    } label: {
                        Text("\(f.rawValue) \(n)")
                            .font(Typeface.body(13))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 34)
                            .foregroundStyle(filter == f ? Token.ink : Token.foreground)
                            .background(filter == f ? Token.foreground : .clear)
                            .overlay(Rectangle().strokeBorder(filter == f ? Token.foreground : Token.input, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                    .accessibilityIdentifier(f == .all ? "filter.all" : "filter.inCamera")
                }
                Spacer(minLength: 0)
            }
            .transaction { $0.animation = nil }
        }
    }

    /// One action from camera to library: a dashed bar while the camera holds slots the library lacks.
    private var pullBar: some View {
        Button { pull() } label: {
            HStack(spacing: 12) {
                Text("C1-7")
                    .font(Typeface.medium(10))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 20)
                    .overlay(Rectangle().strokeBorder(Token.foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                VStack(alignment: .leading, spacing: 3) {
                    Text(pullTitle).font(Typeface.body(15))
                    Text(pullDetail).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if pullItem?.state == .running { BlinkMark() } else { Text(pulling ? "○" : "↓").foregroundStyle(Token.mutedForeground) }
            }
            .foregroundStyle(Token.foreground)
            .padding(12)
            .overlay(Rectangle().strokeBorder(Token.mutedForeground, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pulling)
        .accessibilityIdentifier("pullbar")
        .feedIn()
    }

    private var pullItem: SendQueue.Item? { queue.open.first { $0.kind == .pull } }

    private var pullTitle: String {
        switch pullItem?.state {
        case .running?: return "pulling c1–c7"
        case .waiting?, .failed?: return "pull queued · waits for the cable"
        default: return "pull c1–c7 to library"
        }
    }

    private var pullDetail: String {
        guard let cam = store.camera else { return "plug in the camera once to mark what's on it" }
        let read = "read " + cam.readAt.formatted(date: .omitted, time: .shortened).lowercased()
        let n = missing.count
        let lead = "\(n) in the camera \(n == 1 ? "isn't" : "aren't") in your library"
        return lead + " · " + read
    }

    private var pulling: Bool { queue.open.contains { $0.kind == .pull } }

    private func row(_ r: Recipe) -> some View {
        let slots = store.slots(for: r)
        let state: SlotBadge.State = !slots.isEmpty ? .inCamera(slots) : (queue.queuedSlot(for: r).map { .queued($0) } ?? .none)
        return SwipeRow(id: r.id, open: $swiped, gate: gate,
                        leading: SwipeAction(title: "send", tone: .signal) { sending = r },
                        trailing: [
                            SwipeAction(title: "copy") { duplicate(r) },
                            SwipeAction(title: "delete", tone: .signal) { delete(r) },
                        ]) {
            Button {
                // A long press opens the row's menu; the release that ends it isn't a tap.
                if heldRow == r.id { heldRow = nil; return }
                // Nor is the lift at the end of a sideways swipe.
                guard !gate.blocked else { return }
                nav.cut { nav.recipes.append(.edit(r.id)) }
            } label: {
                EmptyView()
            }
            .buttonStyle(RecipeRowStyle(recipe: r, state: state, unsupported: !r.filmSimulation.onXT30II, held: rowMenu == r.id))
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                heldRow = r.id
                Haptic.play(.medium)
                rowMenu = r.id
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if heldRow == r.id { heldRow = nil } }
            })
            .accessibilityIdentifier("recipe.row")
            .fxMenu(isPresented: Binding(get: { rowMenu == r.id }, set: { if !$0, rowMenu == r.id { rowMenu = nil } }), items: [
                FXMenuItem(title: "send to camera", meta: slots.isEmpty ? "" : slots.map { "c\($0)" }.joined(separator: " ")) { sending = r },
                FXMenuItem(title: "duplicate", meta: "copy") { duplicate(r) },
                FXMenuItem(title: "share as text", meta: "txt") { ShareSheet.present([RecipeText.format(r)]) },
                FXMenuItem(title: "delete", meta: "undo for 5 s") { delete(r) },
            ])
        }
    }

    private func duplicate(_ r: Recipe) {
        let copy = store.duplicate(r)
        overlays.toast("duplicated \(r.name.lowercased())", action: "open") { nav.open(copy.id) }
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

/// `> kodachrome 64 / classic chrome · dr200 ………… [C3]`. Fills bone and shows `>` while pressed.
private struct RecipeRowStyle: ButtonStyle {
    var recipe: Recipe
    var state: SlotBadge.State
    var unsupported: Bool
    /// Lit while its long-press menu is open, so the menu shows whose it is.
    var held = false

    func makeBody(configuration: Configuration) -> some View {
        RecipeRowLabel(recipe: recipe, state: state, unsupported: unsupported, pressed: configuration.isPressed, held: held)
    }
}

private struct RecipeRowLabel: View {
    var recipe: Recipe
    var state: SlotBadge.State
    var unsupported: Bool
    var pressed: Bool
    var held: Bool
    @Environment(\.swiping) private var swiping

    var body: some View {
        let lit = (pressed && !swiping) || held
        return HStack(spacing: 12) {
            Text(">").font(Typeface.body(15)).opacity(lit ? 1 : 0).accessibilityHidden(true)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.name.lowercased())
                    .font(Typeface.body(16))
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typeface.body(13))
                    .foregroundStyle(lit ? Token.ink.opacity(0.7) : (unsupported ? Token.signal : Token.mutedForeground))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SlotBadge(state: state)
                .inverted(lit)
        }
        .foregroundStyle(lit ? Token.ink : Token.foreground)
        .padding(.horizontal, Token.gutter)
        .frame(minHeight: 60)
        .background(lit ? Token.foreground : Token.background)
        .contentShape(Rectangle())
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [recipe.filmSimulation.label.lowercased(), recipe.dynamicRange.label.lowercased()]
        if unsupported { parts.append("not on x-t30 ii") }
        return parts.joined(separator: " · ")
    }
}

private extension View {
    @ViewBuilder func inverted(_ on: Bool) -> some View {
        if on { colorInvert() } else { self }
    }
}

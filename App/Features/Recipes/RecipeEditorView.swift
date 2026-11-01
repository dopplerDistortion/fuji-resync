import SwiftUI
import FujiKit

/// One recipe. Every change saves itself after a short pause; the path bar says when.
struct RecipeEditorView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(Overlays.self) private var overlays
    @Environment(AppNav.self) private var nav

    @State private var draft: Recipe
    @State private var lastSaved: Recipe
    @State private var saving = false
    @State private var savedAt: Date?
    @State private var sending = false
    @State private var more = false
    @State private var folds: Set<String> = ["film", "tone"]
    private let isNew: Bool

    init(recipe: Recipe, isNew: Bool = false) {
        _draft = State(initialValue: recipe)
        _lastSaved = State(initialValue: recipe)
        self.isNew = isNew
    }

    var body: some View {
        TabScreen(path: ["recipes", slug(draft.name)], onPath: { i in if i < 1 { back() } }) {
            SaveMark(saving: saving, savedAt: savedAt, isNew: isNew && savedAt == nil)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        DissolveTitle(text: draft.name.isEmpty ? "untitled" : draft.name.lowercased(), size: 26)
                        placeLine
                    }
                    if !draft.filmSimulation.onXT30II {
                        FaultPanel(title: "x-t30 ii", message: "\(draft.filmSimulation.label.lowercased()) isn't on the x-t30 ii. pick another simulation before sending.")
                    }
                    Panel(title: "name", meta: "\(draft.name.count)/\(Recipe.maxNameLength)") {
                        FXField(text: $draft.name, prompt: "untitled")
                            .padding(10)
                            .onChange(of: draft.name) { _, v in
                                if v.count > Recipe.maxNameLength {
                                    draft.name = String(v.prefix(Recipe.maxNameLength))
                                    Haptic.play(.warning)
                                }
                            }
                    }
                    fold("film", summary: filmSummary) {
                        MenuRow(label: "simulation", selection: $draft.filmSimulation, options: FilmSimulation.allCases,
                                title: { $0.label.lowercased() },
                                note: { $0.onXT30II ? nil : "not on x-t30 ii" })
                        MenuRow(label: "grain", selection: $draft.grain, options: GrainEffect.allCases) { $0.label.lowercased() }
                        MenuRow(label: "color chrome", selection: $draft.colorChrome, options: EffectStrength.allCases) { $0.label.lowercased() }
                        MenuRow(label: "cc fx blue", selection: $draft.colorChromeBlue, options: EffectStrength.allCases) { $0.label.lowercased() }
                    }
                    fold("white balance", summary: wbSummary) {
                        MenuRow(label: "mode", selection: $draft.whiteBalance, options: WhiteBalance.allCases) { $0.label.lowercased() }
                        if draft.whiteBalance == .kelvin {
                            ValueStepper(label: "kelvin", int: $draft.kelvin, range: 2500 ... 10000, step: 100, format: { "\(Int($0))k" })
                        }
                        ValueStepper(label: "shift red", int: $draft.wbShiftRed, range: -9 ... 9)
                        ValueStepper(label: "shift blue", int: $draft.wbShiftBlue, range: -9 ... 9)
                    }
                    fold("tone", summary: toneSummary) {
                        MenuRow(label: "dynamic range", selection: $draft.dynamicRange, options: DynamicRange.allCases) { $0.label.lowercased() }
                        ValueStepper(label: "highlight", value: $draft.highlight, range: -2 ... 4, step: 0.5)
                        ValueStepper(label: "shadow", value: $draft.shadow, range: -2 ... 4, step: 0.5)
                        if draft.filmSimulation.isMonochrome {
                            ValueStepper(label: "mono warm/cool", int: $draft.monoWarmCool, range: -9 ... 9)
                            ValueStepper(label: "mono mag/green", int: $draft.monoMagentaGreen, range: -9 ... 9)
                        } else {
                            ValueStepper(label: "color", int: $draft.color, range: -4 ... 4)
                        }
                        ValueStepper(label: "sharpness", int: $draft.sharpness, range: -4 ... 4)
                        ValueStepper(label: "high iso nr", int: $draft.noiseReduction, range: -4 ... 4)
                        ValueStepper(label: "clarity", int: $draft.clarity, range: -5 ... 5)
                        Text("\(draft.dynamicRange.label.lowercased()) needs iso \(draft.dynamicRange.minimumISO) or higher on the camera.")
                            .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    fold("notes", summary: "not stored on camera") {
                        VStack(alignment: .leading, spacing: 12) {
                            FXTextField(label: "iso", text: $draft.isoNote, prompt: "auto, up to iso 6400")
                            FXTextField(label: "exposure comp.", text: $draft.exposureNote, prompt: "+1/3 to +2/3")
                            FXTextField(label: "notes", text: $draft.notes)
                            FXTextField(label: "source", text: $draft.source, prompt: "url or where it came from")
                        }
                        .padding(14)
                    }
                    fold("as text", summary: "what share sends") {
                        Text(RecipeText.format(draft))
                            .font(Typeface.diagram)
                            .foregroundStyle(Token.mutedForeground)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                }
                .padding(.horizontal, Token.gutter)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        } bottom: {
            BottomBar {
                FXButton("send to camera", .signal, grow: true, haptic: .medium) {
                    commit()
                    sending = true
                }
                .disabled(!draft.filmSimulation.onXT30II)
                FXButton("share", .outline, compact: true) { ShareSheet.present([RecipeText.format(draft)]) }
                FXButton("···", .outline, compact: true, haptic: .selection) { more = true }
                    .accessibilityLabel("more")
                    .fxMenu(isPresented: $more, items: [
                        FXMenuItem(title: "duplicate", meta: "copy") { duplicate() },
                        FXMenuItem(title: "delete", meta: "undo for 5 s") { delete() },
                    ])
            }
        }
        .task(id: draft) {
            guard draft != lastSaved else { return }
            saving = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
        .onDisappear { if draft != lastSaved { commit() } }
        .fxSheet(isPresented: $sending, title: "send to camera", meta: draft.name.lowercased()) {
            SendSheet(recipe: draft.normalized())
        }
    }

    // MARK: Pieces

    private var placeLine: some View {
        let slots = store.slots(for: draft)
        let queued = queue.queuedSlot(for: draft)
        let state: SlotBadge.State = !slots.isEmpty ? .inCamera(slots) : (queued.map { .queued($0) } ?? .none)
        let read = store.camera.map { " · read " + $0.readAt.formatted(date: .omitted, time: .shortened).lowercased() } ?? ""
        let text: String
        switch state {
        case .inCamera: text = "in the camera" + read
        case let .queued(s): text = "queued for c\(s) · waits for the cable"
        case .none: text = store.camera == nil ? "camera never read" : "library only" + read
        }
        return HStack(spacing: 8) {
            SlotBadge(state: state)
            Text(text).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground).lineLimit(1)
        }
    }

    private func fold<C: View>(_ title: String, summary: String, @ViewBuilder content: () -> C) -> some View {
        Fold(title: title, summary: summary, open: Binding(
            get: { folds.contains(title) },
            set: { if $0 { folds.insert(title) } else { folds.remove(title) } }
        ), content: content)
    }

    private var filmSummary: String {
        var parts = [draft.filmSimulation.label.lowercased()]
        if draft.grain != .off { parts.append("grain " + draft.grain.label.lowercased()) }
        if draft.colorChrome != .off { parts.append("cc " + draft.colorChrome.label.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private var wbSummary: String {
        let mode = draft.whiteBalance == .kelvin ? "\(draft.kelvin)k" : draft.whiteBalance.label.lowercased()
        return "\(mode) · r\(ValueStepper.signed(Double(draft.wbShiftRed))) b\(ValueStepper.signed(Double(draft.wbShiftBlue)))"
    }

    private var toneSummary: String {
        "\(draft.dynamicRange.label.lowercased()) · h\(ValueStepper.signed(draft.highlight)) s\(ValueStepper.signed(draft.shadow))"
    }

    // MARK: Actions

    private func commit() {
        guard draft != lastSaved || store.recipe(draft.id) == nil else { saving = false; return }
        store.upsert(draft)
        lastSaved = draft
        saving = false
        savedAt = Date()
    }

    private func back() {
        nav.cut { nav.recipes = [] }
    }

    private func duplicate() {
        commit()
        let copy = store.duplicate(draft)
        nav.cut { nav.recipes = [.edit(copy.id)] }
        overlays.toast("duplicated", detail: copy.name.lowercased())
    }

    private func delete() {
        let gone = draft
        lastSaved = draft // nothing left to autosave
        store.delete([gone.id])
        Haptic.play(.warning)
        back()
        overlays.toast("deleted \(gone.name.lowercased())", action: "undo", duration: 5) {
            store.upsert(gone)
        }
    }
}

/// `▸ film ┄┄┄ classic chrome · grain weak`: a panel that folds to its summary line.
private struct Fold<Content: View>: View {
    var title: String
    var summary: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
                Haptic.play(.selection)
            } label: {
                HStack(spacing: 10) {
                    Text(open ? "▾" : "▸").foregroundStyle(Token.mutedForeground).accessibilityHidden(true)
                    Text(title).systemLabel(Token.foreground)
                    Leader()
                    Text(summary).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary)")
            .accessibilityValue(open ? "open" : "folded")
            if open {
                Rectangle().fill(Token.border).frame(height: Token.rule)
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, 4)
                    .feedIn()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: Token.rule))
        .cropMarks()
        .transaction { $0.animation = nil }
    }
}

/// `■ saving` while a change waits, then `saved 10:31`.
private struct SaveMark: View {
    var saving: Bool
    var savedAt: Date?
    var isNew: Bool

    var body: some View {
        HStack(spacing: 6) {
            if saving {
                BlinkMark()
                Text("saving")
            } else if let savedAt {
                Text("saved " + savedAt.formatted(date: .omitted, time: .shortened).lowercased())
                    .foregroundStyle(Token.mutedForeground)
            } else {
                Text(isNew ? "new" : "saved").foregroundStyle(Token.mutedForeground)
            }
        }
        .font(Typeface.body(12))
        .lineLimit(1)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

func slug(_ s: String) -> String {
    let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(lowered).split(separator: "-").joined(separator: "-").ifEmpty("untitled")
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

import SwiftUI
import FujiKit

struct RecipeEditorView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(USBCameraController.self) private var usb
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Recipe
    @State private var confirmDelete = false
    @State private var showSend = false
    private let isNew: Bool

    init(recipe: Recipe, isNew: Bool = false) {
        _draft = State(initialValue: recipe)
        self.isNew = isNew
    }

    private var saved: Recipe? { store.recipe(draft.id) }
    private var dirty: Bool { saved != draft.normalized() }

    var body: some View {
        Screen(path: ["recipes", slug(draft.name)], title: draft.name.isEmpty ? "untitled" : draft.name.lowercased()) {
            HStack(spacing: 8) {
                Button("save") {
                    store.upsert(draft)
                    if isNew { dismiss() } else if let s = store.recipe(draft.id) { draft = s }
                }
                    .buttonStyle(.fx(.default, compact: true))
                    .disabled(!dirty)
                Button("send to camera") { showSend = true }
                    .buttonStyle(.fx(.signal, compact: true))
                ShareLink(item: RecipeText.format(draft)) { Text("share") }
                    .buttonStyle(.fx(.secondary, compact: true))
                Spacer()
            }

            if !draft.filmSimulation.onXT30II {
                FaultPanel(title: "x-t30 ii", message: "\(draft.filmSimulation.label) isn't on the X-T30 II. pick another simulation before sending.")
            }

            Panel(title: "identity") {
                FXTextField(label: "name · max \(Recipe.maxNameLength)", text: $draft.name)
                    .onChange(of: draft.name) { _, v in if v.count > Recipe.maxNameLength { draft.name = String(v.prefix(Recipe.maxNameLength)) } }
            }

            Panel(title: "film") {
                MenuRow(label: "simulation", selection: $draft.filmSimulation,
                        options: FilmSimulation.allCases.filter { $0.onXT30II || $0 == draft.filmSimulation }) { $0.label.lowercased() }
                MenuRow(label: "grain", selection: $draft.grain, options: GrainEffect.allCases) { $0.label }
                MenuRow(label: "color chrome", selection: $draft.colorChrome, options: EffectStrength.allCases) { $0.label }
                MenuRow(label: "cc fx blue", selection: $draft.colorChromeBlue, options: EffectStrength.allCases) { $0.label }
            }

            Panel(title: "white balance") {
                MenuRow(label: "mode", selection: $draft.whiteBalance, options: WhiteBalance.allCases) { $0.label }
                if draft.whiteBalance == .kelvin {
                    ValueStepper(label: "kelvin", value: Binding(get: { Double(draft.kelvin) }, set: { draft.kelvin = Int($0) }),
                                 range: 2500 ... 10000, step: 100, format: { "\(Int($0))K" })
                }
                ValueStepper(label: "shift red", int: $draft.wbShiftRed, range: -9 ... 9)
                ValueStepper(label: "shift blue", int: $draft.wbShiftBlue, range: -9 ... 9)
            }

            Panel(title: "tone") {
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
            }

            Panel(title: "notes", meta: "not stored on camera") {
                FXTextField(label: "iso", text: $draft.isoNote, prompt: "auto, up to iso 6400")
                FXTextField(label: "exposure comp.", text: $draft.exposureNote, prompt: "+1/3 to +2/3")
                FXTextField(label: "notes", text: $draft.notes)
                FXTextField(label: "source", text: $draft.source, prompt: "url or where it came from")
                Text("\(draft.dynamicRange.label.lowercased()) needs iso \(draft.dynamicRange.minimumISO) or higher on the camera.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
            }

            Panel(title: "text") {
                Text(RecipeText.format(draft))
                    .font(Typeface.diagram)
                    .foregroundStyle(Token.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isNew {
                HStack {
                    Button("duplicate") { _ = store.duplicate(draft) }.buttonStyle(.fx(.ghost))
                    Spacer()
                    Button("delete") { confirmDelete = true }.buttonStyle(.fx(.ghost)).foregroundStyle(Token.signal)
                }
            }
        }
        .confirmationDialog("delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("delete", role: .destructive) { store.delete([draft.id]); dismiss() }
        }
        .sheet(isPresented: $showSend) {
            SendToCameraSheet(recipe: draft.normalized())
                .presentationDetents([.medium, .large])
        }
    }
}

func slug(_ s: String) -> String {
    let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(lowered).split(separator: "-").joined(separator: "-").ifEmpty("untitled")
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

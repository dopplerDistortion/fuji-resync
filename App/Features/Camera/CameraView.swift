import SwiftUI
import FujiKit

/// USB: read and write the camera's custom settings.
struct CameraView: View {
    @Environment(USBCameraController.self) private var usb
    @Environment(RecipeStore.self) private var store
    @State private var picked: CameraPreset?

    var body: some View {
        Screen(path: ["camera"], title: "camera", subtitle: "custom settings c1–c7 over usb-c.") {
            statusPanel

            if case let .fault(message) = usb.phase {
                FaultPanel(title: "usb", message: message + " check the cable and the camera's connection mode, then retry.",
                           action: ("retry", { usb.stop(); usb.start() }))
            }

            if usb.isReady {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ListingHeader(path: "/camera/custom", count: usb.slots.count)
                        Button("reload") { Task { await usb.refreshSlots() } }
                            .buttonStyle(.fx(.ghost)).disabled(usb.busy != nil)
                    }
                    ForEach(usb.slots, id: \.slot) { p in
                        let inLibrary = store.libraryMatch(for: PresetCodec.decode(p)) != nil
                        Button { picked = p } label: {
                            LeaderRow(mark: "C\(p.slot)", label: (p.name.isEmpty ? "unnamed" : p.name).lowercased(),
                                      value: inLibrary ? "in library" : "not in library",
                                      valueColor: inLibrary ? Token.foreground : Token.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                setupSteps
            }

            if !usb.log.isEmpty {
                Panel(title: "log") {
                    ForEach(Array(usb.log.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(Typeface.diagram).foregroundStyle(Token.mutedForeground)
                    }
                }
            }
        }
        .onAppear { usb.start() }
        .sheet(item: $picked) { p in
            SlotDetailSheet(preset: p).presentationDetents([.medium, .large])
        }
    }

    private var statusPanel: some View {
        Panel(title: "usb", meta: usb.busy) {
            switch usb.phase {
            case .idle: StatusMark(state: .idle, text: "not started")
            case .needsPermission:
                StatusMark(state: .fault, text: "no permission to control the camera")
                Text("allow camera control for resync in settings, then come back.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
            case .searching: StatusMark(state: .busy, text: "waiting for a camera on usb-c")
            case let .opening(n): StatusMark(state: .busy, text: "opening \(n.lowercased())")
            case let .ready(n): StatusMark(state: .live, text: "\(n.lowercased()) · ready")
            case .fault: StatusMark(state: .fault, text: "stopped")
            }
        }
    }

    private var setupSteps: some View {
        Panel(title: "setup", meta: "once") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "on the camera: menu → set up → connection setting → pc connection mode → usb raw conv./backup restore.")
                step(2, "use a usb-c data cable under 1.5 m. charge-only cables won't work.")
                step(3, "turn the camera on and plug it into the phone. keep it on while writing.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").foregroundStyle(Token.mark)
            Text(text).foregroundStyle(Token.foreground).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.body(14))
    }
}

extension CameraPreset: Identifiable {
    public var id: Int { slot }
}

struct SlotDetailSheet: View {
    var preset: CameraPreset
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var savedNote: String?

    var body: some View {
        let r = PresetCodec.decode(preset)
        NavigationStack {
            Screen(path: ["camera", "c\(preset.slot)"], title: r.name.lowercased()) {
                Panel(title: "c\(preset.slot)", meta: "on camera") {
                    Text(RecipeText.format(r))
                        .font(Typeface.diagram).foregroundStyle(Token.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("save to library") {
                        let (saved, added) = store.saveFromCamera(r)
                        savedNote = added ? "> saved to recipes." : "> already in recipes as \(saved.name.lowercased())."
                    }
                    .buttonStyle(.fx(.default, compact: true))
                    Button("close") { dismiss() }.buttonStyle(.fx(.secondary, compact: true))
                }
                if let savedNote { Text(savedNote).font(Typeface.body(13)).foregroundStyle(Token.mutedForeground) }
            }
        }
    }
}

/// Pick a slot and write a recipe into it.
struct SendToCameraSheet: View {
    var recipe: Recipe
    @Environment(USBCameraController.self) private var usb
    @Environment(\.dismiss) private var dismiss
    @State private var slot = 1
    @State private var report: PresetService.WriteReport?
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Screen(path: ["camera", "send"], title: "send to c\(slot)") {
                if !usb.isReady {
                    FaultPanel(title: "usb", message: "no camera connected. plug in the camera in usb raw conv./backup restore mode, then open camera to connect.")
                } else {
                    Panel(title: "target") {
                        HStack(spacing: 6) {
                            ForEach(1 ... 7, id: \.self) { n in
                                Button("C\(n)") { slot = n }
                                    .buttonStyle(.fx(slot == n ? .default : .outline, compact: true))
                            }
                        }
                        let current = usb.slots.first { $0.slot == slot }
                        Text("replaces: \((current?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "unnamed")")
                            .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    }
                    Text("iso and exposure compensation aren't part of custom settings. set them on the dials.")
                        .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    Button(usb.busy ?? "write \(recipe.name.lowercased()) → c\(slot)") { confirming = true }
                        .buttonStyle(.fx(.signal))
                        .disabled(usb.busy != nil || !recipe.filmSimulation.onXT30II)
                }

                if let report {
                    if report.ok {
                        Panel(title: "done", meta: "c\(report.slot)") {
                            Text("wrote \(report.written) settings and read them back.").font(Typeface.body(14)).foregroundStyle(Token.foreground)
                        }
                    } else {
                        FaultPanel(title: "c\(report.slot)", message: "the camera rejected \(report.rejected.count) setting(s):\n" + report.rejected.joined(separator: "\n") + "\ncheck the drive mode is S and iso is high enough for the dynamic range, then send again.")
                    }
                }
            }
            .confirmationDialog("overwrite c\(slot) on the camera?", isPresented: $confirming, titleVisibility: .visible) {
                Button("write c\(slot)", role: .destructive) {
                    Task { report = await usb.write(recipe, to: slot) }
                }
            }
        }
    }
}

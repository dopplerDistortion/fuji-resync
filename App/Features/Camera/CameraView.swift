import UIKit
import SwiftUI
import FujiKit

/// The camera tab: the Bluetooth link, the USB cable, the queue, and what's in C1–C7.
struct CameraView: View {
    @Environment(USBCameraController.self) private var usb
    @Environment(BLECameraController.self) private var ble
    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(Overlays.self) private var overlays
    @Environment(AppNav.self) private var nav
    @State private var picked: CameraPreset?
    @State private var pullID: UUID?

    var body: some View {
        TabScreen(path: ["camera"]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if ble.savedCameraID == nil { PairPanel() } else { linkPanel }
                    usbPanel
                    if case let .fault(message) = usb.phase {
                        FaultPanel(title: "usb", message: message + " check the cable and the camera's connection mode, then try again.",
                                   action: ("try again", { usb.stop(); usb.start() }))
                    }
                    if !queue.items.isEmpty { queuePanel }
                    slotsPanel
                    if !usb.isReady, store.camera == nil { setupSteps }
                    if !usb.log.isEmpty { logPanel }
                }
                .padding(.horizontal, Token.gutter)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        } bottom: {
            BottomBar {
                FXButton(pullLabel, grow: true) {
                    pullID = queue.pull()
                }
                .disabled(isPulling)
                if ble.savedCameraID != nil {
                    FXButton("forget", .ghost, haptic: .selection) {
                        overlays.confirm("forget camera?", message: "resync stops geotagging and drops the pairing. pair again from this tab any time.", confirm: "forget") {
                            ble.forget()
                            Haptic.play(.warning)
                        }
                    }
                }
            }
        }
        .onAppear { usb.start() }
        .fxSheet(item: $picked, title: { "c\($0.slot)" }, meta: { _ in "on camera" }) { p in
            SlotDetail(preset: p) { picked = nil }
        }
    }

    private var isPulling: Bool {
        guard let id = pullID, let item = queue.item(id) else { return false }
        return item.state == .running
    }

    private var pullLabel: String {
        if let id = pullID, let item = queue.item(id) {
            switch item.state {
            case .running: return "reading c1–c7"
            case .waiting: return "pull queued · plug in"
            default: break
            }
        }
        return "pull c1–c7 to library"
    }

    // MARK: Panels

    private var linkPanel: some View {
        Panel(title: "bluetooth", meta: ble.isLinked ? "linked" : "paired") {
            VStack(alignment: .leading, spacing: 0) {
                switch ble.phase {
                case let .linked(n):
                    LeaderRow(label: "camera", value: n.lowercased(), valueColor: Token.foreground)
                    LeaderRow(label: "geotags sent", value: "\(ble.syncCount)")
                    Toggle("geotag every photo", isOn: Binding(get: { ble.autoSync }, set: { ble.autoSync = $0 }))
                        .toggleStyle(.fx)
                case .connecting, .scanning:
                    HStack(spacing: 8) { BlinkMark(); Text("linking") }.padding(14)
                case let .fault(msg):
                    Text(msg).font(Typeface.body(13)).foregroundStyle(Token.signal).padding(14)
                    FXButton("reconnect", .outline, compact: true) { ble.reconnect() }.padding([.horizontal, .bottom], 14)
                case .off, .unauthorized:
                    StatusMark(state: .fault, text: ble.phase == .off ? "bluetooth is off" : "bluetooth not allowed").padding(14)
                case .idle:
                    StatusMark(state: .idle, text: "camera not in range").padding(14)
                    FXButton("reconnect", .outline, compact: true) { ble.reconnect() }.padding([.horizontal, .bottom], 14)
                }
            }
        }
    }

    private var usbPanel: some View {
        Panel(title: "usb-c", meta: usb.busy) {
            VStack(alignment: .leading, spacing: 8) {
                switch usb.phase {
                case .idle: StatusMark(state: .idle, text: "not started")
                case .needsPermission:
                    StatusMark(state: .fault, text: "no permission to control the camera")
                    Text("allow camera control for resync in settings, then come back.")
                        .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    FXButton("open settings", .outline, compact: true) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                case .searching:
                    HStack(spacing: 8) { ScanGlyph(); Text("waiting for a camera on usb-c").foregroundStyle(Token.mutedForeground) }
                case let .opening(n): StatusMark(state: .busy, text: "opening \(n.lowercased())")
                case let .ready(n): StatusMark(state: .live, text: "\(n.lowercased()) · ptp ready")
                case .fault: StatusMark(state: .fault, text: "stopped")
                }
            }
            .font(Typeface.body(13))
            .padding(14)
        }
    }

    private var queuePanel: some View {
        Panel(title: "/queue", meta: queue.open.isEmpty ? "clear" : "\(queue.open.count) open") {
            VStack(spacing: 0) {
                ForEach(Array(queue.items.enumerated()), id: \.element.id) { i, item in
                    QueueRow(item: item)
                        .stepIn(i)
                }
                if queue.items.contains(where: { !$0.isOpen }) {
                    HStack {
                        Spacer()
                        FXButton("clear finished", .ghost, compact: true, haptic: .selection) { queue.clearFinished() }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private var slotsPanel: some View {
        let rows: [SlotLine]
        if usb.isReady, !usb.slots.isEmpty {
            rows = usb.slots.sorted { $0.slot < $1.slot }.map { SlotLine(slot: $0.slot, name: $0.name, recipe: PresetCodec.decode($0), preset: $0) }
        } else {
            rows = (store.camera?.slots ?? []).map { SlotLine(slot: $0.slot, name: $0.name, recipe: $0.recipe, preset: nil) }
        }
        let meta: String = usb.isReady ? "live" : store.camera.map { "read " + $0.readAt.formatted(date: .abbreviated, time: .shortened).lowercased() } ?? "never read"
        return Panel(title: "/camera/custom", meta: meta) {
            if rows.isEmpty {
                Text(usb.isReady ? "reading c1–c7" : "plug the camera in once to read c1–c7.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.slot) { i, row in
                        let match = store.libraryMatch(for: row.recipe)
                        let queued = queue.open.first { $0.slot == row.slot }
                        SelectRow(title: "c\(row.slot)  " + (row.name.isEmpty ? "unnamed" : row.name).lowercased(),
                                  subtitle: queued.map { "queued: " + $0.title } ?? row.recipe.filmSimulation.label.lowercased(),
                                  meta: match == nil ? "not in library" : "in library",
                                  muted: match == nil) {
                            if let match {
                                nav.open(match.id)
                            } else if let p = row.preset {
                                picked = p
                            } else {
                                overlays.toast("plug the camera in to save c\(row.slot)")
                            }
                        }
                        .stepIn(i)
                    }
                }
            }
        }
    }

    private var setupSteps: some View {
        Panel(title: "usb setup", meta: "once") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "on the camera: menu › set up › connection setting › pc connection mode › usb raw conv./backup restore.")
                step(2, "use a usb-c data cable. charge-only cables won't work.")
                step(3, "turn the camera on and plug it in. queued sends run by themselves.")
            }
            .padding(14)
        }
    }

    private var logPanel: some View {
        Panel(title: "usb log", meta: "last \(min(usb.log.count, 8))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(usb.log.suffix(8).enumerated()), id: \.offset) { _, line in
                    Text(line.lowercased()).font(Typeface.diagram).foregroundStyle(Token.mutedForeground)
                        .lineLimit(2)
                }
            }
            .padding(14)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").foregroundStyle(Token.mutedForeground)
            Text(text).foregroundStyle(Token.foreground).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.body(13))
    }
}

private struct SlotLine {
    var slot: Int
    var name: String
    var recipe: Recipe
    var preset: CameraPreset?
}

private struct QueueRow: View {
    var item: SendQueue.Item
    @Environment(SendQueue.self) private var queue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch item.state {
                case .waiting: Text("○").foregroundStyle(Token.mutedForeground)
                case .running: BlinkMark()
                case .done: Text("■").foregroundStyle(Token.foreground)
                case .failed: Text("✕").foregroundStyle(Token.signal)
                }
                Text(item.title).lineLimit(1)
                Spacer(minLength: 8)
                switch item.state {
                case .waiting:
                    FXButton("drop", .ghost, compact: true, haptic: .selection) { queue.remove(item.id) }
                case .failed:
                    FXButton("retry", .outline, compact: true) { queue.retry(item.id) }
                default:
                    EmptyView()
                }
            }
            .font(Typeface.body(14))
            Text(item.status)
                .font(Typeface.body(12))
                .foregroundStyle(failed ? Token.signal : Token.mutedForeground)
            ForEach(Array(item.lines.enumerated()), id: \.offset) { i, line in
                TypedText(text: line, duration: 0.16, delay: Double(i) * 0.08)
                    .font(Typeface.diagram)
                    .foregroundStyle(line.hasPrefix("✕") ? Token.signal : Token.mutedForeground)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Token.border).frame(height: 1) }
        .feedIn()
    }

    private var failed: Bool { if case .failed = item.state { return true } else { return false } }
}

extension CameraPreset: Identifiable {
    public var id: Int { slot }
}

/// A slot whose settings aren't in the library: read it, save it.
private struct SlotDetail: View {
    var preset: CameraPreset
    var close: () -> Void
    @Environment(RecipeStore.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Overlays.self) private var overlays

    var body: some View {
        let r = PresetCodec.decode(preset)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(r.name.lowercased()).font(Typeface.medium(16)).padding(.horizontal, Token.gutter)
                Text(RecipeText.format(r))
                    .font(Typeface.diagram).foregroundStyle(Token.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Token.gutter)
                FXButton("save to library", grow: true) {
                    let (saved, added) = store.saveFromCamera(r)
                    close()
                    overlays.toast(added ? "saved \(saved.name.lowercased())" : "already in the library as \(saved.name.lowercased())",
                                   action: "open") { nav.open(saved.id) }
                }
                .padding(.horizontal, Token.gutter)
            }
        }
    }
}

// MARK: Send

/// Pick a slot (4 + 3, as on the camera's Q menu) and send. Writes now if the cable is in,
/// otherwise queues and writes the moment it is.
struct SendSheet: View {
    var recipe: Recipe
    @Environment(USBCameraController.self) private var usb
    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @State private var slot = 1
    @State private var sent: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !recipe.filmSimulation.onXT30II {
                    FaultPanel(title: "x-t30 ii", message: "\(recipe.filmSimulation.label.lowercased()) isn't on the x-t30 ii. pick another simulation in the recipe, then send.")
                }
                grid
                swapLine
                Text("iso and exposure compensation aren't part of custom settings. set them on the dials.")
                    .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if let sent, let item = queue.item(sent) {
                    progress(item)
                } else {
                    FXButton(usb.isReady ? "write to c\(slot)" : "queue for c\(slot)", .signal, grow: true, haptic: .medium) {
                        sent = queue.write(recipe, to: slot)
                    }
                    .disabled(!recipe.filmSimulation.onXT30II || (usb.busy != nil && usb.isReady))
                    Text(usb.isReady ? "the camera is on the cable. resync writes and reads the slot back."
                                     : "no cable now. resync writes it the moment the camera is plugged in.")
                        .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                }
            }
            .padding(.horizontal, Token.gutter)
            .padding(.bottom, 20)
        }
        .onAppear { slot = store.slots(for: recipe).first ?? queue.queuedSlot(for: recipe) ?? 1 }
    }

    private var grid: some View {
        let on = store.slots(for: recipe)
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow { ForEach(1 ... 4, id: \.self) { cell($0, on: on) } }
            GridRow {
                ForEach(5 ... 7, id: \.self) { cell($0, on: on) }
                Color.clear.frame(height: 1)
            }
        }
    }

    private func cell(_ n: Int, on: [Int]) -> some View {
        let selected = n == slot
        let name = current(n)
        return Button {
            slot = n
            sent = nil
            Haptic.play(.selection)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("C\(n)").font(Typeface.medium(16))
                    Spacer(minLength: 0)
                    if on.contains(n) { Text("■").font(.system(size: 9)) }
                }
                Text(name ?? "—").font(Typeface.body(10)).lineLimit(1)
                    .opacity(0.75)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .foregroundStyle(selected ? Token.ink : Token.foreground)
            .background(selected ? Token.foreground : Token.card)
            .overlay(Rectangle().strokeBorder(selected ? Token.foreground : Token.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
        .accessibilityLabel("slot \(n), \(name ?? "unknown")\(on.contains(n) ? ", already holds this recipe" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var swapLine: some View {
        let from = current(slot)
        let already = store.slots(for: recipe).contains(slot)
        return HStack(spacing: 6) {
            Text("c\(slot)").foregroundStyle(Token.foreground)
            if already {
                Text("already holds \(recipe.name.lowercased())").foregroundStyle(Token.mutedForeground)
            } else {
                Text(from ?? "unknown").foregroundStyle(Token.mutedForeground).strikethrough(from != nil, color: Token.mark)
                Text("→").foregroundStyle(Token.mark)
                Text(recipe.name.lowercased()).foregroundStyle(Token.foreground)
            }
        }
        .font(Typeface.body(13))
        .lineLimit(1)
    }

    private func current(_ n: Int) -> String? {
        if let p = usb.slots.first(where: { $0.slot == n }) { return (p.name.isEmpty ? "unnamed" : p.name).lowercased() }
        if let s = store.camera?.slots.first(where: { $0.slot == n }) { return (s.name.isEmpty ? "unnamed" : s.name).lowercased() }
        return nil
    }

    @ViewBuilder private func progress(_ item: SendQueue.Item) -> some View {
        switch item.state {
        case .waiting:
            Panel(title: "queued", meta: "c\(slot)") {
                HStack(spacing: 8) { Text("○").foregroundStyle(Token.mutedForeground); Text("waits for the cable. you can close this.") }
                    .font(Typeface.body(13)).padding(14)
            }
            .feedIn()
        case .running:
            Panel(title: "writing", meta: "c\(slot)") {
                HStack(spacing: 8) { BlinkMark(); Text(usb.busy ?? "writing c\(slot)") }
                    .font(Typeface.body(13)).padding(14)
            }
        case let .done(s):
            Panel(title: "done", meta: "c\(slot)") {
                HStack(spacing: 8) { Text("■"); DissolveTitle(text: s, font: Typeface.body(13)) }.padding(14)
            }
        case let .failed(s, retry):
            FaultPanel(title: "c\(slot)", message: s + (retry ? "" : ". check the drive mode is s and the iso is high enough for the dynamic range, then send again."),
                       line: item.lines.isEmpty ? nil : item.lines.joined(separator: "\n"),
                       action: ("send again", { queue.retry(item.id) }))
        }
    }
}

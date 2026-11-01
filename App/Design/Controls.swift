import SwiftUI

// resync draws every overlay itself: sheets, menus, toasts and alerts. UIKit only hosts a
// sheet or a menu in a clear full-screen cover that it shows and hides with no animation;
// the scrim, the panel and their stepped motion are ours. Where Apple owns an element
// (permission prompts, the share sheet, the file picker, the keyboard), resync owns the
// words around it.

// MARK: Cover

/// Hosts a sheet or a menu in a clear full-screen cover with no system slide. The cover stays
/// up while `closing` is true, so the panel can step out before the cut.
private struct FXCover<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// How long the panel takes to step out, in milliseconds.
    var exit: UInt64 = 120
    /// Runs once the cover is gone, so a menu action can present the next thing.
    var onDismiss: () -> Void = {}
    @ViewBuilder var cover: (_ closing: Bool, _ dismiss: @escaping () -> Void) -> Cover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var closing = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $shown, onDismiss: onDismiss) {
                cover(closing) { isPresented = false }
                    .presentationBackground(.clear)
                    .font(Typeface.body())
                    .foregroundStyle(Token.foreground)
                    .tint(Token.foreground)
                    .preferredColorScheme(.dark)
            }
            .onChange(of: isPresented) { _, on in on ? open() : close() }
            .onChange(of: shown) { _, s in if !s, isPresented { isPresented = false } }
            .onAppear { if isPresented { open() } }
    }

    private func open() {
        closing = false
        guard !shown else { return }
        cut { shown = true }
    }

    private func close() {
        guard shown, !closing else { return }
        closing = true
        let wait = reduceMotion ? 0 : exit
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait * 1_000_000) }
            guard !isPresented else { closing = false; return } // opened again meanwhile
            cut { shown = false }
            closing = false
        }
    }

    private func cut(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }
}

// MARK: Sheets

/// A sheet in the system's dress: square, a 1 px bone top rule, a `━━━` grab bar, and a title
/// that dissolves in. It feeds up from the bottom edge in four steps and drops out in three;
/// the scrim darkens in two. Drag the grab bar up to grow, down to close; tap above to close.
private struct SheetPanel<Content: View>: View {
    var title: String
    var meta: String?
    var detents: Set<PresentationDetent>
    var closing: Bool
    var dismiss: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var large: Bool?
    /// The fraction of the panel still below the bottom edge.
    @State private var feed: CGFloat = 1
    @State private var drag: CGFloat = 0

    private var canGrow: Bool { detents.contains(.large) && detents.count > 1 }
    private var startsLarge: Bool { !detents.contains(.medium) }

    var body: some View {
        GeometryReader { g in
            let isLarge = large ?? startsLarge
            let height = (g.size.height * (isLarge ? 0.92 : 0.6)).rounded()
            ZStack(alignment: .bottom) {
                Token.background.opacity(scrim)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Token.background.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)
                        .accessibilityElement()
                        .accessibilityLabel("close")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { dismiss() }
                        .accessibilityIdentifier("sheet.close")
                    panel(isLarge: isLarge)
                        .frame(height: height)
                        .offset(y: height * feed + drag)
                }
            }
        }
        .accessibilityAction(.escape) { dismiss() }
        .transaction { $0.animation = nil }
        .task { await step(from: 1, to: 0, steps: 4) }
        .onChange(of: closing) { _, c in
            if c { Task { await step(from: feed, to: 1, steps: 3) } }
        }
    }

    /// Two steps of dark: none while the panel is out, then 36 %, then 72 %.
    private var scrim: Double { feed >= 1 ? 0 : (feed > 0.5 ? 0.36 : 0.72) }

    private func panel(isLarge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    guard canGrow else { return }
                    large = !isLarge
                    Haptic.play(.selection)
                } label: {
                    Text("━━━")
                        .font(Typeface.body(10)).tracking(3)
                        .foregroundStyle(Token.mark)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLarge ? "shrink" : "grow")
                .accessibilityHidden(!canGrow)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    DissolveTitle(text: title, size: 24)
                    Spacer(minLength: 0)
                    if let meta { Text(meta).systemLabel().lineLimit(1) }
                }
                .padding(.horizontal, Token.gutter)
                .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
            .gesture(grab(isLarge: isLarge))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Token.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Token.foreground).frame(height: 1) }
    }

    /// The panel follows the finger in 8 pt steps, never smoothly.
    private func grab(isLarge: Bool) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in drag = max(0, (v.translation.height / 8).rounded(.down) * 8) }
            .onEnded { v in
                let moved = v.translation.height
                if moved > 120 || v.predictedEndTranslation.height > 320 {
                    dismiss() // steps out from where the finger left it
                    return
                }
                drag = 0
                if canGrow, moved < -40, !isLarge { large = true; Haptic.play(.selection) }
                else if canGrow, moved > 40, isLarge { large = false; Haptic.play(.selection) }
            }
    }

    @MainActor private func step(from start: CGFloat, to end: CGFloat, steps: Int) async {
        guard !reduceMotion else { feed = end; return }
        for s in 1 ... steps {
            try? await Task.sleep(nanoseconds: 40_000_000)
            feed = start + (end - start) * CGFloat(s) / CGFloat(steps)
        }
    }
}

/// Keeps the last item while its sheet steps out, so the panel has something to draw.
private struct FXItemSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    var title: (Item) -> String
    var meta: ((Item) -> String?)?
    var detents: Set<PresentationDetent>
    var sheet: (Item) -> Sheet
    @State private var held: Item?

    func body(content: Content) -> some View {
        content
            .onAppear { if let item { held = item } }
            .onChange(of: item?.id) { _, _ in if let item { held = item } }
            .modifier(FXCover(isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } })) { closing, dismiss in
                if let it = item ?? held {
                    SheetPanel(title: title(it), meta: meta?(it), detents: detents, closing: closing, dismiss: dismiss) {
                        sheet(it)
                    }
                }
            })
    }
}

extension View {
    func fxSheet<C: View>(isPresented: Binding<Bool>, title: String, meta: String? = nil,
                          detents: Set<PresentationDetent> = [.medium, .large],
                          @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(FXCover(isPresented: isPresented) { closing, dismiss in
            SheetPanel(title: title, meta: meta, detents: detents, closing: closing, dismiss: dismiss) {
                content()
            }
        })
    }

    func fxSheet<Item: Identifiable, C: View>(item: Binding<Item?>, title: @escaping (Item) -> String,
                                             meta: ((Item) -> String?)? = nil,
                                             detents: Set<PresentationDetent> = [.medium, .large],
                                             @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(FXItemSheet(item: item, title: title, meta: meta, detents: detents, sheet: content))
    }
}

// MARK: Menu

struct FXMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var meta: String?
    var run: () -> Void
}

extension View {
    /// A menu anchored to the view: bone border and crop marks, rows that step in and light
    /// bone when pressed. It opens above the view in the lower half of the screen, below it
    /// in the upper half. The chosen action runs once the menu is gone.
    func fxMenu(isPresented: Binding<Bool>, items: [FXMenuItem]) -> some View {
        modifier(FXMenuModifier(isPresented: isPresented, items: items))
    }
}

private struct FXMenuModifier: ViewModifier {
    @Binding var isPresented: Bool
    var items: [FXMenuItem]
    @State private var anchor: CGRect = .zero
    @State private var pending: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { anchor = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in anchor = f }
                }
            }
            .modifier(FXCover(isPresented: $isPresented, exit: 60, onDismiss: {
                let run = pending
                pending = nil
                run?()
            }) { closing, dismiss in
                MenuPanel(items: items, anchor: anchor, closing: closing, dismiss: dismiss) { item in
                    pending = item.run
                    dismiss()
                }
            })
    }
}

private struct MenuPanel: View {
    var items: [FXMenuItem]
    var anchor: CGRect
    var closing: Bool
    var dismiss: () -> Void
    var pick: (FXMenuItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dark = false

    var body: some View {
        GeometryReader { g in
            let space = g.frame(in: .global)
            let a = anchor.offsetBy(dx: -space.minX, dy: -space.minY)
            let width = min(280, g.size.width - Token.gutter * 2)
            let x = min(max(Token.gutter, a.maxX - width), g.size.width - Token.gutter - width)
            let below = a.midY < g.size.height / 2
            ZStack(alignment: .topLeading) {
                Token.background.opacity(closing ? 0 : (dark || reduceMotion ? 0.6 : 0.3))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityElement()
                    .accessibilityLabel("close")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss() }
                    .accessibilityIdentifier("menu.close")
                VStack(spacing: 0) {
                    if !below { Spacer(minLength: 0) }
                    list
                        .frame(width: width)
                        .padding(.leading, x)
                        .padding(.top, below ? a.maxY + 6 : 0)
                        .padding(.bottom, below ? 0 : g.size.height - a.minY + 6)
                    if below { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .opacity(closing ? 0 : 1) // a menu leaves on a hard cut
            }
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape) { dismiss() }
        .transaction { $0.animation = nil }
        .task {
            try? await Task.sleep(nanoseconds: 40_000_000)
            dark = true
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                SelectRow(title: item.title, meta: item.meta ?? "") { pick(item) }
                    .stepIn(i)
            }
        }
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(Token.foreground, lineWidth: 1))
        .cropMarks()
    }
}

// MARK: Toggle and segmented control

/// `label ┄┄ [ON|off]`: two cells, the bone fill moves in one step.
struct FXToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            Haptic.play(.selection)
        } label: {
            HStack(spacing: 10) {
                configuration.label
                    .font(Typeface.body(15)).foregroundStyle(Token.foreground)
                Leader()
                HStack(spacing: 0) {
                    cell("on", lit: configuration.isOn, fill: Token.foreground, ink: Token.ink)
                    cell("off", lit: !configuration.isOn, fill: Token.muted, ink: Token.foreground)
                }
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }

    private func cell(_ t: String, lit: Bool, fill: Color, ink: Color) -> some View {
        Text(t)
            .systemLabel(lit ? ink : Token.mutedForeground)
            .frame(width: 36, height: 34)
            .background(lit ? fill : .clear)
    }
}

extension ToggleStyle where Self == FXToggleStyle {
    static var fx: FXToggleStyle { FXToggleStyle() }
}

/// Bordered cells; the selected one fills bone.
struct Segmented<T: Hashable>: View {
    var label: String
    @Binding var selection: T
    var options: [T]
    var title: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Typeface.body(15)).foregroundStyle(Token.foreground)
                .lineLimit(1).fixedSize()
            Leader()
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    Button {
                        selection = o
                        Haptic.play(.selection)
                    } label: {
                        Text(title(o))
                            .font(Typeface.body(12))
                            .frame(minWidth: 46, minHeight: 36)
                            .padding(.horizontal, 4)
                            .foregroundStyle(o == selection ? Token.ink : Token.foreground)
                            .background(o == selection ? Token.foreground : .clear)
                            .overlay(alignment: .leading) {
                                if i > 0 { Rectangle().fill(Token.input).frame(width: 1) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(o == selection ? .isSelected : [])
                }
            }
            .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

// MARK: Toasts and alerts

/// App-wide overlays: one toast at a time, one alert at a time. No system alerts.
@MainActor
@Observable
final class Overlays {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var detail: String?
        var action: String?
        var duration: Double
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    struct Alert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirm: String
        var run: () -> Void
    }

    private(set) var toast: Toast?
    @ObservationIgnored private var toastRun: (() -> Void)?
    var alert: Alert?

    func toast(_ text: String, detail: String? = nil, action: String? = nil, duration: Double = 3.5, run: (() -> Void)? = nil) {
        toast = Toast(text: text, detail: detail, action: action, duration: duration)
        toastRun = run
    }

    func tapToast() {
        let run = toastRun
        dismissToast()
        run?()
    }

    func dismissToast() { toast = nil; toastRun = nil }

    func confirm(_ title: String, message: String, confirm: String, run: @escaping () -> Void) {
        alert = Alert(title: title, message: message, confirm: confirm, run: run)
        Haptic.play(.medium)
    }
}

/// Draws the current toast above the bottom bar and the current alert in the middle.
struct OverlayHost: View {
    @Environment(Overlays.self) private var overlays
    var bottomInset: CGFloat

    var body: some View {
        ZStack {
            if let alert = overlays.alert {
                Token.background.opacity(0.72).ignoresSafeArea()
                    .onTapGesture { overlays.alert = nil }
                VStack(alignment: .leading, spacing: 14) {
                    DissolveTitle(text: alert.title, size: 22)
                    Text(alert.message)
                        .font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        FXButton(alert.confirm, grow: true, haptic: .medium) {
                            overlays.alert = nil
                            alert.run()
                        }
                        FXButton("cancel", .outline, haptic: .selection) { overlays.alert = nil }
                    }
                }
                .padding(18)
                .background(Token.background)
                .overlay(Rectangle().strokeBorder(Token.foreground, lineWidth: 1))
                .cropMarks()
                .padding(.horizontal, 28)
                .accessibilityAddTraits(.isModal)
            }
            if let toast = overlays.toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast)
                        .id(toast.id)
                        .padding(.horizontal, Token.gutter)
                        .padding(.bottom, bottomInset)
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct ToastView: View {
    var toast: Overlays.Toast
    @Environment(Overlays.self) private var overlays
    @State private var start = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    DissolveTitle(text: toast.text, font: Typeface.body(14))
                    if let d = toast.detail {
                        Text(d).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let a = toast.action {
                    FXButton(a, .outline, compact: true, haptic: .selection) { overlays.tapToast() }
                }
            }
            TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                let left = 1 - ctx.date.timeIntervalSince(start) / toast.duration
                Text(String(repeating: "█", count: max(0, Int(left * 24))) + String(repeating: "░", count: 24 - max(0, Int(left * 24))))
                    .font(Typeface.body(8)).tracking(1)
                    .foregroundStyle(Token.mark)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: 1))
        .task {
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1e9))
            if overlays.toast == toast { overlays.dismissToast() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
    }
}

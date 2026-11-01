import SwiftUI

// Native controls, restyled to the goksen.ing system. Where Apple owns an element (permission
// prompts, the share sheet, notifications, the keyboard), resync owns the words around it.

// MARK: Sheets

/// A sheet in the system's dress: square, a 1 px bone top rule, a `━━━` grab bar of our own,
/// and a title that dissolves in.
struct FXSheet<Content: View>: View {
    var title: String
    var meta: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("━━━")
                .font(Typeface.body(10)).tracking(3)
                .foregroundStyle(Token.mark)
                .frame(maxWidth: .infinity, minHeight: 22)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                DissolveTitle(text: title, size: 24)
                Spacer(minLength: 0)
                if let meta { Text(meta).systemLabel().lineLimit(1) }
            }
            .padding(.horizontal, Token.gutter)
            .padding(.bottom, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Token.background)
        .overlay(alignment: .top) { Rectangle().fill(Token.foreground).frame(height: 1) }
        .font(Typeface.body())
        .foregroundStyle(Token.foreground)
        .presentationCornerRadius(0)
        .presentationBackground(Token.background)
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }
}

extension View {
    func fxSheet<C: View>(isPresented: Binding<Bool>, title: String, meta: String? = nil,
                          detents: Set<PresentationDetent> = [.medium, .large],
                          @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented) {
            FXSheet(title: title, meta: meta) { content() }
                .presentationDetents(detents)
        }
    }

    func fxSheet<Item: Identifiable, C: View>(item: Binding<Item?>, title: @escaping (Item) -> String,
                                             meta: ((Item) -> String?)? = nil,
                                             detents: Set<PresentationDetent> = [.medium, .large],
                                             @ViewBuilder content: @escaping (Item) -> C) -> some View {
        sheet(item: item) { it in
            FXSheet(title: title(it), meta: meta?(it)) { content(it) }
                .presentationDetents(detents)
        }
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
    /// A popover menu anchored to the view: bone border, rows that light bone when pressed.
    func fxMenu(isPresented: Binding<Bool>, items: [FXMenuItem]) -> some View {
        popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    SelectRow(title: item.title, meta: item.meta ?? "") {
                        isPresented.wrappedValue = false
                        item.run()
                    }
                    .stepIn(i)
                }
            }
            .frame(minWidth: 260)
            .background(Token.card)
            .overlay(Rectangle().strokeBorder(Token.foreground, lineWidth: 1))
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Token.card)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: Toggle and segmented control

/// `label ┄┄ [ON|off]`: two cells, the bone fill moves in one step.
struct FXToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
                .font(Typeface.body(14)).foregroundStyle(Token.foreground)
            Leader()
            Button {
                configuration.isOn.toggle()
                Haptic.play(.selection)
            } label: {
                HStack(spacing: 0) {
                    cell("on", lit: configuration.isOn, fill: Token.foreground, ink: Token.ink)
                    cell("off", lit: !configuration.isOn, fill: Token.muted, ink: Token.foreground)
                }
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
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
            Text(label).font(Typeface.body(14)).foregroundStyle(Token.foreground)
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
        .accessibilityElement(children: .combine)
    }
}

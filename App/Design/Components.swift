import SwiftUI

// MARK: Panel with crop marks

/// A card-coloured panel with a 1 px rule and crop marks at the corners.
struct Panel<Content: View>: View {
    var title: String?
    var meta: String?
    var tone: Color = Token.border
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || meta != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).systemLabel(Token.foreground) }
                    Spacer(minLength: 8)
                    if let meta { Text(meta).systemLabel() }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(tone, lineWidth: Token.rule))
        .overlay(CropMarks().stroke(Token.mark, lineWidth: 1))
    }
}

struct CropMarks: Shape {
    var length: CGFloat = 8
    var inset: CGFloat = -4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX, y: r.minY), 1, 1), (CGPoint(x: r.maxX, y: r.minY), -1, 1),
            (CGPoint(x: r.minX, y: r.maxY), 1, -1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
        ]
        for (c, sx, sy) in corners {
            p.move(to: CGPoint(x: c.x + sx * length, y: c.y)); p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x, y: c.y + sy * length))
        }
        return p
    }
}

// MARK: Path bar

/// `~/recipes/kodachrome-64` — the location line at the top of every screen.
struct PathBar: View {
    var segments: [String]

    var body: some View {
        HStack(spacing: 0) {
            Text("~").foregroundStyle(Token.mutedForeground)
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                Text("/").foregroundStyle(Token.mark)
                Text(s).foregroundStyle(i == segments.count - 1 ? Token.foreground : Token.mutedForeground)
            }
            BlinkingCursor().padding(.leading, 4)
            Spacer()
        }
        .font(Typeface.body(13))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(segments.joined(separator: ", "))
    }
}

// MARK: Rows

/// `> label ┄┄┄┄┄┄ value` index row with a dotted leader.
struct LeaderRow: View {
    var mark: String = ">"
    var label: String
    var value: String = ""
    var valueColor: Color = Token.mutedForeground

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).foregroundStyle(Token.mark)
            Text(label).foregroundStyle(Token.foreground).lineLimit(1)
            Leader()
            Text(value).foregroundStyle(valueColor).lineLimit(1)
        }
        .font(Typeface.body(15))
        .contentShape(Rectangle())
    }
}

struct Leader: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: g.size.height - 4))
                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 4))
            }
            .stroke(Token.mark, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        .frame(minWidth: 12, maxHeight: 14)
    }
}

/// `ls /recipes · 12 entries` section header.
struct ListingHeader: View {
    var command: String = "ls"
    var path: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(command).foregroundStyle(Token.mutedForeground)
            Text(path).foregroundStyle(Token.foreground)
            if let count { Text("· \(count) \(count == 1 ? "entry" : "entries")").foregroundStyle(Token.mutedForeground) }
            Spacer()
        }
        .font(Typeface.body(13))
    }
}

// MARK: Buttons

enum FXVariant { case `default`, secondary, outline, ghost, signal }

struct FXButtonStyle: ButtonStyle {
    var variant: FXVariant = .default
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Typeface.medium(compact ? 13 : 15))
            .textCase(.lowercase)
            .padding(.horizontal, variant == .ghost ? 0 : (compact ? 10 : 14))
            .padding(.vertical, variant == .ghost ? 0 : (compact ? 6 : 10))
            .frame(minHeight: variant == .ghost ? nil : 44)
            .foregroundStyle(foreground)
            .background(background.opacity(pressed ? 0.8 : 1))
            .overlay(Rectangle().strokeBorder(stroke, lineWidth: Token.rule))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch variant {
        case .default, .signal: return Token.ink
        case .secondary, .outline, .ghost: return Token.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .default: return Token.foreground
        case .signal: return Token.signal
        case .secondary: return Token.muted
        case .outline, .ghost: return .clear
        }
    }

    private var stroke: Color {
        switch variant {
        case .outline: return Token.input
        default: return .clear
        }
    }
}

extension ButtonStyle where Self == FXButtonStyle {
    static func fx(_ v: FXVariant = .default, compact: Bool = false) -> FXButtonStyle { FXButtonStyle(variant: v, compact: compact) }
}

// MARK: Badge

struct Badge: View {
    var text: String
    var color: Color = Token.mutedForeground

    var body: some View {
        Text(text)
            .systemLabel(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

/// Live status dot + label, e.g. `■ linked`.
struct StatusMark: View {
    enum State { case idle, busy, live, fault }
    var state: State
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text("■").foregroundStyle(color)
            Text(text).foregroundStyle(state == .idle ? Token.mutedForeground : Token.foreground)
        }
        .font(Typeface.body(13))
    }

    private var color: Color {
        switch state {
        case .idle: return Token.mark
        case .busy: return Token.warn
        case .live: return Token.foreground
        case .fault: return Token.signal
        }
    }
}

// MARK: Fault

/// Fault copy states the problem and the next step. Appears with a hard cut (no animation).
struct FaultPanel: View {
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        Panel(title: "fault", meta: title, tone: Token.signal) {
            Text(message)
                .font(Typeface.body(14))
                .foregroundStyle(Token.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.label, action: action.run).buttonStyle(.fx(.outline, compact: true))
            }
        }
        .transaction { $0.animation = nil }
    }
}

// MARK: Motion

/// Prompt cursor: blinks five times, then holds. Reduced motion shows it steady.
struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var blinks = 0

    var body: some View {
        Text("█")
            .foregroundStyle(Token.foreground)
            .opacity(visible ? 1 : 0)
            .task {
                guard !reduceMotion else { return }
                while blinks < 10 {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    visible.toggle(); blinks += 1
                }
                visible = true
            }
            .accessibilityHidden(true)
    }
}

/// Page title that dissolves in: each character lands within 300 ms in random order.
struct DissolveTitle: View {
    var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Set<Int> = []

    var body: some View {
        let chars = Array(text)
        HStack(spacing: 0) {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i])).opacity(reduceMotion || shown.contains(i) ? 1 : 0)
            }
        }
        .font(Typeface.display(26))
        .foregroundStyle(Token.foreground)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
        .task(id: text) {
            shown = []
            guard !reduceMotion else { return }
            let order = chars.indices.shuffled()
            let step = UInt64(300_000_000 / max(order.count, 1))
            for i in order {
                shown.insert(i)
                try? await Task.sleep(nanoseconds: step)
            }
        }
    }
}

// MARK: Screen scaffold

/// Standard screen: path bar, dissolving title, scrollable content on the base ground.
struct Screen<Content: View>: View {
    var path: [String]
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PathBar(segments: path)
                VStack(alignment: .leading, spacing: 6) {
                    DissolveTitle(text: title)
                    if let subtitle {
                        Text(subtitle).font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                    }
                }
                content
            }
            .padding(.horizontal, Token.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: 66 * 9, alignment: .leading) // ~66ch reading width
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Token.background.ignoresSafeArea())
        .toolbarBackground(Token.background, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// `[-]  +0.5  [+]` stepper in the terminal idiom.
struct ValueStepper: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String = { v in
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return v > 0 ? "+" + s : s
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Typeface.body(15)).foregroundStyle(Token.foreground)
            Leader()
            Button { value = max(range.lowerBound, value - step) } label: { Text("−").frame(width: 20) }
                .buttonStyle(.fx(.outline, compact: true))
                .disabled(value <= range.lowerBound)
            Text(format(value))
                .font(Typeface.medium(15))
                .foregroundStyle(value == 0 ? Token.mutedForeground : Token.foreground)
                .frame(minWidth: 46)
                .monospacedDigit()
            Button { value = min(range.upperBound, value + step) } label: { Text("+").frame(width: 20) }
                .buttonStyle(.fx(.outline, compact: true))
                .disabled(value >= range.upperBound)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

extension ValueStepper {
    /// Integer convenience.
    init(label: String, int: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label
        self._value = Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0) })
        self.range = Double(range.lowerBound) ... Double(range.upperBound)
        self.step = 1
    }
}

/// `label ┄┄┄ [value ▾]` menu picker.
struct MenuRow<T: Hashable & Identifiable>: View {
    var label: String
    @Binding var selection: T
    var options: [T]
    var title: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Typeface.body(15)).foregroundStyle(Token.foreground)
            Leader()
            Menu {
                Picker(label, selection: $selection) {
                    ForEach(options) { Text(title($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title(selection)).lineLimit(1)
                    Text("▾").foregroundStyle(Token.mutedForeground)
                }
                .font(Typeface.medium(14))
                .foregroundStyle(Token.foreground)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
            }
        }
    }
}

/// Text field styled as an input with the input-edge token.
struct FXTextField: View {
    var label: String
    @Binding var text: String
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).systemLabel()
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Token.mark))
                .font(Typeface.body(15))
                .foregroundStyle(Token.foreground)
                .tint(Token.foreground)
                .padding(10)
                .background(Token.background)
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
        }
    }
}

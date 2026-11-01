import SwiftUI

// MARK: Panel with crop marks

/// A card-coloured panel with a 1 px rule and the site's crop marks: two corner strokes
/// outside the frame, top-left and bottom-right, as on a print proof.
struct Panel<Content: View>: View {
    var title: String?
    var meta: String?
    var tone: Color = Token.border
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || meta != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).systemLabel(Token.foreground) }
                    Spacer(minLength: 8)
                    if let meta { Text(meta).systemLabel().lineLimit(1) }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                Rectangle().fill(Token.border).frame(height: Token.rule)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Token.card)
        .overlay(Rectangle().strokeBorder(tone, lineWidth: Token.rule))
        .cropMarks()
    }
}

/// Corner strokes outside a frame. `.proof` is the site's pair (top-left, bottom-right);
/// `.all` draws four, used for the focus brackets.
struct CropMarks: Shape {
    enum Corners { case proof, all }
    var corners: Corners = .proof
    var length: CGFloat = 10
    var inset: CGFloat = -6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        var list: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: r.minX, y: r.minY), 1, 1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1)]
        if corners == .all { list += [(CGPoint(x: r.maxX, y: r.minY), -1, 1), (CGPoint(x: r.minX, y: r.maxY), 1, -1)] }
        for (c, sx, sy) in list {
            p.move(to: CGPoint(x: c.x + sx * length, y: c.y)); p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x, y: c.y + sy * length))
        }
        return p
    }
}

extension View {
    func cropMarks(_ color: Color = Token.mark) -> some View {
        overlay(CropMarks().stroke(color, lineWidth: 1).allowsHitTesting(false))
    }
}

// MARK: Path bar

/// `~/recipes/kodachrome-64█` at the top of every screen. Each segment is a link back up the
/// path (it glitches when tapped); the trailing slot holds the link mark or the save state.
struct PathBar<Trailing: View>: View {
    var segments: [String]
    var onSegment: (Int) -> Void = { _ in }
    @ViewBuilder var trailing: Trailing
    @State private var taps: [Int: Int] = [:]

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                segment("~", index: -1, current: segments.isEmpty)
                ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                    Text("/").foregroundStyle(Token.mark)
                    segment(s, index: i, current: i == segments.count - 1)
                }
                BlinkingCursor()
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .font(Typeface.body(13))
        .padding(.horizontal, Token.gutter)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Token.border).frame(height: Token.rule) }
        .background(Token.background)
    }

    @ViewBuilder private func segment(_ s: String, index: Int, current: Bool) -> some View {
        if current {
            GlitchText(text: s, trigger: taps[index, default: 0])
                .foregroundStyle(Token.foreground)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("path.current")
        } else {
            Button {
                taps[index, default: 0] += 1
                Haptic.play(.selection)
                onSegment(index)
            } label: {
                GlitchText(text: s, trigger: taps[index, default: 0])
                    .foregroundStyle(Token.mutedForeground)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(index < 0 ? "home" : "back to \(s)")
        }
    }
}

extension PathBar where Trailing == EmptyView {
    init(segments: [String], onSegment: @escaping (Int) -> Void = { _ in }) {
        self.init(segments: segments, onSegment: onSegment) { EmptyView() }
    }
}

// MARK: Rows

/// `> label ┄┄┄┄┄┄ value` with a dotted leader. 44 pt tall at least, so it's a fair tap target.
struct LeaderRow: View {
    var mark: String = ">"
    var label: String
    var value: String = ""
    var valueColor: Color = Token.mutedForeground

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).foregroundStyle(Token.mark).accessibilityHidden(true)
            Text(label).foregroundStyle(Token.foreground).lineLimit(2).layoutPriority(1)
            Leader().accessibilityHidden(true)
            Text(value).foregroundStyle(valueColor).lineLimit(1)
        }
        .font(Typeface.body(15))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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

/// `ls /recipes · 12 entries · 4 in camera` section header.
struct ListingHeader: View {
    var command: String = "ls"
    var path: String
    var count: Int?
    var extra: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(command).foregroundStyle(Token.mutedForeground)
            Text(path).foregroundStyle(Token.foreground)
            if let count { Text("· \(count) \(count == 1 ? "entry" : "entries")").foregroundStyle(Token.mutedForeground) }
            if let extra { Text("· \(extra)").foregroundStyle(Token.mutedForeground) }
            Spacer(minLength: 0)
        }
        .font(Typeface.body(14))
        .lineLimit(1)
    }
}

// MARK: Buttons

enum FXVariant { case `default`, secondary, outline, ghost, signal }

struct FXButtonStyle: ButtonStyle {
    var variant: FXVariant = .default
    var compact = false
    var grow = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Typeface.medium(compact ? 13 : 15))
            .textCase(.lowercase)
            .lineLimit(1)
            .padding(.horizontal, variant == .ghost ? 6 : (compact ? 10 : 16))
            .frame(maxWidth: grow ? .infinity : nil, minHeight: 44)
            .foregroundStyle(foreground)
            .background(background.opacity(pressed ? 0.8 : 1))
            .overlay(Rectangle().strokeBorder(stroke, lineWidth: Token.rule))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
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

    private var stroke: Color { variant == .outline ? Token.input : .clear }
}

extension ButtonStyle where Self == FXButtonStyle {
    static func fx(_ v: FXVariant = .default, compact: Bool = false, grow: Bool = false) -> FXButtonStyle {
        FXButtonStyle(variant: v, compact: compact, grow: grow)
    }
}

/// A text button whose label glitches when tapped, the touch version of the site's hover.
struct FXButton: View {
    var title: String
    var variant: FXVariant = .default
    var compact = false
    var grow = false
    var haptic: Haptic? = .light
    var action: () -> Void
    @State private var taps = 0

    init(_ title: String, _ variant: FXVariant = .default, compact: Bool = false, grow: Bool = false,
         haptic: Haptic? = .light, action: @escaping () -> Void) {
        self.title = title; self.variant = variant; self.compact = compact; self.grow = grow
        self.haptic = haptic; self.action = action
    }

    var body: some View {
        Button {
            taps += 1
            if let haptic { Haptic.play(haptic) }
            action()
        } label: {
            GlitchText(text: title, trigger: taps)
        }
        .buttonStyle(.fx(variant, compact: compact, grow: grow))
    }
}

/// The strip of pinned actions above the tab bar: a 1 px top rule on the ground colour.
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, Token.gutter)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Token.background)
            .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: Token.rule) }
    }
}

// MARK: Badges and marks

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

/// Where a recipe is: bone `C3` in that slot at the last read, dashed `C4` queued, `—` library only.
struct SlotBadge: View {
    enum State: Equatable { case inCamera([Int]), queued(Int), none }
    var state: State

    var body: some View {
        switch state {
        case let .inCamera(slots):
            Text(slots.map { "C\($0)" }.joined(separator: " "))
                .badgeShape()
                .foregroundStyle(Token.ink)
                .background(Token.foreground)
                .accessibilityLabel("in camera, slot \(slots.map(String.init).joined(separator: " and "))")
        case let .queued(slot):
            Text("C\(slot)")
                .badgeShape()
                .foregroundStyle(Token.foreground)
                .overlay(Rectangle().strokeBorder(Token.foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .accessibilityLabel("queued for slot \(slot)")
        case .none:
            Text("—")
                .badgeShape()
                .foregroundStyle(Token.mutedForeground)
                .overlay(Rectangle().strokeBorder(Token.mark, lineWidth: 1))
                .accessibilityLabel("not in camera")
        }
    }
}

private extension View {
    func badgeShape() -> some View {
        font(Typeface.medium(10)).tracking(0.6)
            .padding(.horizontal, 4)
            .frame(minWidth: 26, minHeight: 20)
    }
}

/// Live status dot + label, e.g. `■ linked`. The square is hidden from VoiceOver.
struct StatusMark: View {
    enum State { case idle, busy, live, fault }
    var state: State
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            if state == .busy { BlinkMark() } else { Text("■").foregroundStyle(color).accessibilityHidden(true) }
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

/// Fault copy states the problem and the next step. Enters with the Hard cut.
struct FaultPanel: View {
    var title: String
    var message: String
    var line: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("fault · \(title)")
                .systemLabel(Token.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Token.signal)
            if let line {
                Text(line).font(Typeface.body(13)).foregroundStyle(Token.signal)
            }
            Text(message)
                .font(Typeface.body(14))
                .foregroundStyle(Token.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                FXButton(action.label, .outline, compact: true, action: action.run)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Token.background)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: Token.rule))
        .cropMarks()
        .hardCut()
        .accessibilityElement(children: .contain)
    }
}

// MARK: Cursor and title

/// Prompt cursor: blinks five times, then holds. Blinks five more times when `restart` changes
/// (a field gaining focus). Steady under Reduce Motion.
struct BlinkingCursor: View {
    var restart: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        Text("█")
            .foregroundStyle(Token.foreground)
            .opacity(visible ? 1 : 0)
            .task(id: restart) {
                visible = true
                guard !reduceMotion else { return }
                for _ in 0 ..< 10 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    visible.toggle()
                }
                visible = true
            }
            .accessibilityHidden(true)
    }
}

/// Title that dissolves in: each character lands within 300 ms, in random order.
struct DissolveTitle: View {
    var text: String
    var size: CGFloat = 30
    /// Overrides the display face, for dissolving body text (toasts, results).
    var font: Font?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Set<Int> = []
    @State private var settled = false

    var body: some View {
        let chars = Array(text)
        HStack(spacing: 0) {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i])).opacity(reduceMotion || settled || shown.contains(i) ? 1 : 0)
            }
        }
        .font(font ?? Typeface.display(size))
        .foregroundStyle(Token.foreground)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
        .task(id: text) {
            shown = []; settled = false
            guard !reduceMotion else { settled = true; return }
            let order = chars.indices.shuffled()
            let step = UInt64(300_000_000 / max(order.count, 1))
            for i in order {
                shown.insert(i)
                try? await Task.sleep(nanoseconds: step)
            }
            settled = true
        }
    }
}

// MARK: Stepper

/// `label ┄┄ [−] +0.5 [+]`. Tap steps once; hold repeats after 400 ms, every 90 ms. The end of
/// the range plays a warning tick. Tapping the value opens a grid of every value for big jumps.
struct ValueStepper: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String = ValueStepper.signed
    @State private var picking = false
    @State private var bumps = 0

    static func signed(_ v: Double) -> String {
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return v > 0 ? "+" + s : s
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Typeface.body(14)).foregroundStyle(Token.foreground).lineLimit(1).layoutPriority(1)
            Leader()
            RepeatButton(symbol: "−", label: "decrease \(label)", enabled: value > range.lowerBound) { nudge(-1) }
            Button { picking = true; Haptic.play(.selection) } label: {
                GlitchText(text: format(value), trigger: bumps)
                    .font(Typeface.medium(15))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? Token.mutedForeground : Token.foreground)
                    .frame(minWidth: 58, minHeight: 40)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Token.mark).frame(height: 1).mask(DashMask())
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            RepeatButton(symbol: "+", label: "increase \(label)", enabled: value < range.upperBound) { nudge(1) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: _ = nudge(1)
            case .decrement: _ = nudge(-1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("stepper.\(label)")
        .fxSheet(isPresented: $picking, title: label) {
            ValueGrid(values: values, current: value, format: format) { v in
                value = v; bumps += 1; picking = false
                Haptic.play(.selection)
            }
        }
    }

    private var values: [Double] {
        stride(from: range.lowerBound, through: range.upperBound + step / 2, by: step).map { ($0 / step).rounded() * step }
    }

    /// Returns false at the end of the range.
    @discardableResult private func nudge(_ dir: Double) -> Bool {
        let next = min(range.upperBound, max(range.lowerBound, value + dir * step))
        guard next != value else { Haptic.play(.warning); return false }
        value = next; bumps += 1
        Haptic.play(.selection)
        return true
    }
}

private struct DashMask: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                var x: CGFloat = 0
                while x < g.size.width { p.addRect(CGRect(x: x, y: 0, width: 3, height: 1)); x += 5 }
            }
        }
    }
}

/// A 44 × 40 step button that repeats while held. Fills bone while pressed.
private struct RepeatButton: View {
    var symbol: String
    var label: String
    var enabled: Bool
    var action: () -> Bool
    @State private var held = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        Text(symbol)
            .font(Typeface.body(17))
            .frame(width: 44, height: 40)
            .foregroundStyle(held ? Token.ink : Token.foreground)
            .background(held ? Token.foreground : .clear)
            .overlay(Rectangle().strokeBorder(held ? Token.foreground : Token.input, lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                _ = action()
            }
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 24, perform: {
                guard enabled else { return }
                repeater = Task { @MainActor in
                    while !Task.isCancelled {
                        if !action() { break }
                        try? await Task.sleep(nanoseconds: 90_000_000)
                    }
                }
            }, onPressingChanged: { pressing in
                held = pressing && enabled
                if !pressing { repeater?.cancel(); repeater = nil }
            })
            .accessibilityAddTraits(.isButton)
            .allowsHitTesting(enabled)
            .accessibilityLabel(label)
            .transaction { $0.animation = nil }
    }
}

/// Every value of a stepper in a grid; the current one is bone.
private struct ValueGrid: View {
    var values: [Double]
    var current: Double
    var format: (Double) -> String
    var pick: (Double) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: values.count > 20 ? 6 : 5)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Button { pick(v) } label: {
                        Text(format(v))
                            .font(Typeface.medium(14)).monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(v == current ? Token.ink : Token.foreground)
                            .background(v == current ? Token.foreground : .clear)
                            .overlay(Rectangle().strokeBorder(v == current ? Token.foreground : Token.input, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .stepIn(i / 6)
                }
            }
            .padding(.horizontal, Token.gutter)
            Text("big jumps here; − and + for fine steps.").systemLabel()
                .padding(.top, 12)
        }
    }
}

extension ValueStepper {
    /// Integer convenience.
    init(label: String, int: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, format: ((Double) -> String)? = nil) {
        self.label = label
        self._value = Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0.rounded()) })
        self.range = Double(range.lowerBound) ... Double(range.upperBound)
        self.step = Double(step)
        if let format { self.format = format }
    }
}

// MARK: Menu row

/// `label ┄┄┄ [value ▾]`: opens a sheet of options as rows. Options the camera can't use
/// are listed, muted, with the reason.
struct MenuRow<T: Hashable & Identifiable>: View {
    var label: String
    @Binding var selection: T
    var options: [T]
    var title: (T) -> String
    var note: (T) -> String? = { _ in nil }
    @State private var open = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Typeface.body(14)).foregroundStyle(Token.foreground).lineLimit(1).layoutPriority(1)
            Leader()
            Button { open = true; Haptic.play(.selection) } label: {
                HStack(spacing: 8) {
                    Text(title(selection)).lineLimit(1)
                    Text("▾").foregroundStyle(Token.mutedForeground)
                }
                .font(Typeface.medium(14))
                .foregroundStyle(Token.foreground)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
                .overlay(Rectangle().strokeBorder(Token.input, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label), \(title(selection))")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .fxSheet(isPresented: $open, title: label) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                        SelectRow(title: title(o), meta: note(o) ?? (o == selection ? "■" : ""), selected: o == selection, muted: note(o) != nil) {
                            selection = o
                            open = false
                        }
                        .stepIn(i)
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Token.border).frame(height: 1) }
            }
        }
    }
}

/// A row that fills bone and shows `>` while pressed or selected, and glitches its name.
struct SelectRow: View {
    var title: String
    var subtitle: String?
    var meta: String = ""
    var selected = false
    var muted = false
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            Haptic.play(.selection)
            action()
        } label: {
            EmptyView()
        }
        .buttonStyle(SelectRowStyle(title: title, subtitle: subtitle, meta: meta, selected: selected, muted: muted, taps: taps))
    }
}

struct SelectRowStyle: ButtonStyle {
    var title: String
    var subtitle: String?
    var meta: String
    var selected: Bool
    var muted: Bool
    var taps: Int

    func makeBody(configuration: Configuration) -> some View {
        let lit = configuration.isPressed || selected
        return HStack(spacing: 10) {
            Text(">").opacity(lit ? 1 : 0).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                GlitchText(text: title, trigger: taps)
                    .foregroundStyle(lit ? Token.ink : (muted ? Token.mutedForeground : Token.foreground))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(Typeface.body(12))
                        .foregroundStyle(lit ? Token.ink.opacity(0.7) : Token.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(meta).font(Typeface.body(12)).foregroundStyle(lit ? Token.ink.opacity(0.7) : Token.mutedForeground)
        }
        .font(Typeface.body(15))
        .padding(.horizontal, Token.gutter)
        .frame(minHeight: 48)
        .background(lit ? Token.foreground : Token.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Token.border).frame(height: 1) }
        .contentShape(Rectangle())
        .transaction { $0.animation = nil }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Text field

/// Input edge #6b6a66, bone when focused. The cursor blinks again each time it gains focus.
struct FXTextField: View {
    var label: String
    @Binding var text: String
    var prompt: String = ""
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).systemLabel()
            FXField(text: $text, prompt: prompt, mark: ">")
        }
    }
}

/// The bare field: `> text█` in a 44 pt box.
struct FXField: View {
    @Binding var text: String
    var prompt: String = ""
    var mark: String = ">"
    @FocusState private var focused: Bool
    @State private var focusCount = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(mark).foregroundStyle(Token.mutedForeground).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Token.mutedForeground))
                .focused($focused)
                .font(Typeface.body(15))
                .foregroundStyle(Token.foreground)
                .tint(Token.foreground)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if text.isEmpty && !focused { BlinkingCursor(restart: focusCount) }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Token.background)
        .overlay(Rectangle().strokeBorder(focused ? Token.foreground : Token.input, lineWidth: 1))
        .onChange(of: focused) { _, f in if f { focusCount += 1 } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focused {
                    Spacer()
                    Button("done") { focused = false }
                        .font(Typeface.medium(15))
                        .foregroundStyle(Token.foreground)
                }
            }
        }
    }
}

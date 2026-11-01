import SwiftUI
import UIKit

// The goksen.ing motion set (src/lib/motion.ts + globals.css), ported to SwiftUI.
// Every effect moves in discrete steps: no springs, no easing curves. Under Reduce Motion
// each one shows its final state at once.

enum Motion {
    /// Block glyphs the Glitch and the Aftershock draw with.
    static let blocks: [Character] = Array("█▓▒░▚▞▖▘")

    /// Swaps about a third of the non-space characters for block glyphs.
    static func corrupt(_ text: String) -> String {
        String(text.map { c in
            !c.isWhitespace && Double.random(in: 0 ..< 1) < 1.0 / 3 ? (blocks.randomElement() ?? c) : c
        })
    }

    /// `▓▓▓▓░░░░`: a fraction drawn in block cells.
    static func bar(_ fraction: Double, cells: Int = 12) -> String {
        let on = Int((min(max(fraction, 0), 1) * Double(cells)).rounded())
        return String(repeating: "▓", count: on) + String(repeating: "░", count: cells - on)
    }

    /// `label ........ value`, padded to a column like the boot log.
    static func dots(_ label: String, _ value: String, width: Int = 28) -> String {
        label + " " + String(repeating: ".", count: max(2, width - label.count)) + " " + value
    }
}

// MARK: Haptics

/// One place for haptics, so the settings switch can turn them off. Faults always play.
enum Haptic {
    case selection, light, medium, heavy, success, warning, error

    static let settingKey = "haptics"

    @MainActor static func play(_ h: Haptic) {
        let on = UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
        guard on || h == .error else { return }
        switch h {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: Glitch

/// Text that glitches once each time `trigger` changes: four corrupt frames in 240 ms, drawn
/// as two slices shifted sideways. At most three runs a second. VoiceOver reads the real text.
struct GlitchText: View {
    var text: String
    var trigger: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: String?
    @State private var shift: CGFloat = 0
    @State private var cut: CGFloat = 0.5
    @State private var lastRun = Date.distantPast

    private static let shifts: [CGFloat] = [-2, 3, -3, 1]
    private static let cuts: [CGFloat] = [0.55, 0.3, 0.7, 0.45]

    var body: some View {
        Text(text)
            .opacity(frame == nil ? 1 : 0)
            .overlay(alignment: .leading) {
                if let frame {
                    ZStack(alignment: .leading) {
                        Text(frame)
                            .mask { slice(top: true) }
                            .offset(x: shift)
                        Text(frame)
                            .mask { slice(top: false) }
                            .offset(x: -shift)
                    }
                    .fixedSize()
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: trigger) { _, _ in run() }
            .accessibilityLabel(text)
    }

    private func slice(top: Bool) -> some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                if !top { Spacer(minLength: 0) }
                Rectangle().frame(height: g.size.height * (top ? cut : 1 - cut))
                if top { Spacer(minLength: 0) }
            }
        }
    }

    private func run() {
        guard !reduceMotion, Date().timeIntervalSince(lastRun) >= 0.333 else { return }
        lastRun = Date()
        Task { @MainActor in
            for i in 0 ..< 4 {
                frame = Motion.corrupt(text)
                shift = Self.shifts[i]
                cut = Self.cuts[i]
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            frame = nil
        }
    }
}

// MARK: Hard cut

/// A Fault's entrance: two cuts to signal with a tear in 400 ms, then the static Fault.
struct HardCut: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 4

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    switch phase {
                    case 0:
                        Rectangle().fill(Token.signal)
                    case 1:
                        Rectangle().fill(Token.signal)
                            .frame(height: g.size.height * 0.52).offset(x: 6)
                    case 3:
                        Rectangle().fill(Token.signal)
                            .frame(height: g.size.height * 0.48)
                            .offset(x: -6, y: g.size.height * 0.52)
                    default:
                        EmptyView()
                    }
                }
                .allowsHitTesting(false)
            }
            .transaction { $0.animation = nil }
            .task {
                guard !reduceMotion else { return }
                for (p, ms) in [(0, 80), (1, 60), (2, 80), (3, 80)] as [(Int, UInt64)] {
                    phase = p
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                }
                phase = 4
            }
    }
}

extension View {
    func hardCut() -> some View { modifier(HardCut()) }
}

// MARK: Feed

/// Appears by feeding up from below in four steps over 160 ms, like paper out of a printer.
struct FeedIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remaining: CGFloat = 1
    var steps = 4

    func body(content: Content) -> some View {
        let r = remaining
        return content
            .visualEffect { v, proxy in v.offset(y: proxy.size.height * r) }
            .clipped()
            .task {
                guard !reduceMotion else { remaining = 0; return }
                for s in 1 ... steps {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    remaining = CGFloat(steps - s) / CGFloat(steps)
                }
            }
    }
}

/// Appears after `index` × 28 ms in one step: rows of a list, a fold or a menu step in one by one.
struct StepIn: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .task {
                guard !reduceMotion else { return }
                try? await Task.sleep(nanoseconds: UInt64(index) * 28_000_000)
                shown = true
            }
    }
}

extension View {
    func feedIn() -> some View { modifier(FeedIn()) }
    func stepIn(_ index: Int) -> some View { modifier(StepIn(index: index)) }
}

// MARK: Typed text

/// Types its text in, one character per step, like a Boot log line.
struct TypedText: View {
    var text: String
    var duration: Double = 0.24
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 0

    var body: some View {
        // The full text sits underneath, hidden, so the line's width never jumps.
        Text(text).opacity(0)
            .overlay(alignment: .leading) { Text(String(text.prefix(reduceMotion ? text.count : count))).fixedSize() }
            .accessibilityLabel(text)
            .task(id: text) {
                count = 0
                guard !reduceMotion, !text.isEmpty else { count = text.count; return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                let step = UInt64(duration / Double(text.count) * 1e9)
                for i in 1 ... text.count {
                    count = i
                    try? await Task.sleep(nanoseconds: step)
                }
            }
    }
}

/// A Boot log: each line types in its own slot of `total` seconds.
struct BootLog: View {
    var lines: [String]
    var total: Double = 1.2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let slot = total / Double(max(lines.count, 1))
                TypedText(text: line, duration: slot, delay: slot * Double(i))
            }
        }
        .font(Typeface.diagram)
        .foregroundStyle(Token.mutedForeground)
        .lineLimit(1)
    }
}

// MARK: Busy marks

/// `■` that blinks while something runs (pairing, saving). Steady under Reduce Motion.
struct BlinkMark: View {
    var color: Color = Token.warn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { ctx in
            let on = reduceMotion || Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 2 == 0
            Text("■").foregroundStyle(color).opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// `▖▘▝▗` turning every 150 ms while scanning.
struct ScanGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = Array("▖▘▝▗")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { ctx in
            let i = reduceMotion ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / 0.15) % 4
            Text(String(Self.frames[i]))
        }
        .accessibilityHidden(true)
    }
}

// MARK: Aftershock

/// Screen faults only: after the Hard cut, a random tremor every 1.4–5.2 s. Never more than
/// two flashes a second (WCAG 2.3.1). Paused under Reduce Motion and in the background.
@MainActor
@Observable
final class Aftershock {
    enum Kind: CaseIterable { case tear, scan, noise, slice, jolt, takeover }

    struct Shock: Equatable {
        var kind: Kind
        var top: CGFloat      // 0…1 of the panel height
        var band: CGFloat     // points
        var shift: CGFloat    // points, either way
        var emote: String?
        var frame: Int = 0
    }

    private(set) var shock: Shock?
    private var previous: Kind?

    private static let weights: [Kind: Int] = [.tear: 3, .scan: 2, .noise: 3, .slice: 3, .jolt: 2, .takeover: 1]
    private static let durations: [Kind: ClosedRange<Double>] = [
        .tear: 0.24 ... 0.42, .scan: 0.3 ... 0.45, .noise: 0.24 ... 0.4,
        .slice: 0.2 ... 0.32, .jolt: 0.16 ... 0.28, .takeover: 0.48 ... 0.64,
    ]
    private static let emoteOdds: [Kind: Double] = [.tear: 0.5, .scan: 0.5, .noise: 0.6, .slice: 0.35, .jolt: 0, .takeover: 1]
    static let emotes = ["(x_x)", "(o_O)", "(>_<)", "(;_;)", "(-_-)", "(@_@)", "(T_T)", "(O_O;)", "(._.)", "(=_=)", "(+_+)", "(?_?)", "[x_x]", "(^_^;)", "\\(o_o)/", "(>o_o)>", "<(o_o<)", "D:", ":-/"]
    private var deck: [String] = []

    func run(reduceMotion: () -> Bool) async {
        var first = true
        while !Task.isCancelled {
            let wait = first ? Double.random(in: 2.2 ... 3.6) : Double.random(in: 1.4 ... 5.2)
            first = false
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            if Task.isCancelled { break }
            guard !reduceMotion(), UIApplication.shared.applicationState == .active else { continue }
            let kind = pick()
            let ms = Double.random(in: Self.durations[kind] ?? 0.3 ... 0.3)
            let emote = Double.random(in: 0 ..< 1) < (Self.emoteOdds[kind] ?? 0) ? deal() : nil
            var s = Shock(kind: kind, top: .random(in: 0.04 ... 0.88), band: emote == nil ? .random(in: 6 ... 48) : .random(in: 28 ... 56),
                          shift: .random(in: 3 ... 14) * (Bool.random() ? 1 : -1), emote: emote)
            for f in 0 ..< 3 {
                s.frame = f
                shock = s
                try? await Task.sleep(nanoseconds: UInt64(ms / 3 * 1e9))
            }
            shock = nil
        }
        shock = nil
    }

    private func pick() -> Kind {
        let kinds = Kind.allCases.filter { $0 != previous }
        var r = Int.random(in: 0 ..< kinds.reduce(0) { $0 + (Self.weights[$1] ?? 1) })
        for k in kinds {
            r -= Self.weights[k] ?? 1
            if r < 0 { previous = k; return k }
        }
        previous = kinds.last
        return kinds.last ?? .jolt
    }

    private func deal() -> String {
        if deck.isEmpty { deck = Self.emotes.shuffled() }
        return deck.removeLast()
    }
}

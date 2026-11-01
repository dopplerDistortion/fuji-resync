import SwiftUI

/// A fault that owns the whole screen (Bluetooth off, Bluetooth not allowed). It enters with the
/// Hard cut, then Aftershocks run over it until the fault clears.
struct ScreenFault<Actions: View>: View {
    var title: String
    var message: String
    var line: String?
    @ViewBuilder var actions: Actions
    @State private var shocks = Aftershock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                panel
                    .offset(x: shocks.shock?.kind == .jolt ? (shocks.shock?.shift ?? 0) / 2 : 0)
                if let s = shocks.shock {
                    shockLayer(s, size: g.size)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .hardCut()
        .task {
            let rm = reduceMotion
            await shocks.run(reduceMotion: { rm })
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("fault · \(title)")
                .systemLabel(Token.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Token.signal)
            if let line {
                Text(line).font(Typeface.diagram).foregroundStyle(Token.signal)
            }
            Text(message)
                .font(Typeface.body(16))
                .foregroundStyle(Token.foreground)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) { actions }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Token.background)
        .overlay(Rectangle().strokeBorder(Token.signal, lineWidth: 1))
        .cropMarks()
        .padding(Token.gutter)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func shockLayer(_ s: Aftershock.Shock, size: CGSize) -> some View {
        let y = s.top * size.height
        switch s.kind {
        case .tear, .slice:
            // A band of the panel, shifted sideways, with red edges on a slice.
            panel
                .offset(x: s.shift * (s.frame == 1 ? -0.5 : 1))
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: size.width, height: s.band).offset(y: y)
                }
                .overlay(alignment: .topLeading) {
                    if s.kind == .slice {
                        VStack(spacing: s.band - 2) {
                            Rectangle().fill(Token.signal).frame(height: 1)
                            Rectangle().fill(Token.signal).frame(height: 1)
                        }
                        .offset(y: y)
                    }
                }
                .overlay(alignment: .topLeading) { emote(s, y: y) }
        case .scan:
            Rectangle().fill(Token.foreground.opacity(0.8))
                .frame(width: size.width, height: 2)
                .offset(y: y + CGFloat(s.frame) * s.band / 3)
                .overlay(alignment: .topLeading) { emote(s, y: y) }
        case .noise:
            Text(String((0 ..< 80).map { _ in Array("░▒▓█ ").randomElement()! }))
                .font(Typeface.body(s.band > 24 ? 18 : 10))
                .foregroundStyle(Token.mark)
                .lineLimit(1)
                .frame(width: size.width, height: s.band, alignment: .leading)
                .clipped()
                .background(Token.background)
                .offset(y: y)
                .overlay(alignment: .topLeading) { emote(s, y: y) }
        case .jolt:
            EmptyView()
        case .takeover:
            ZStack {
                Token.background
                Text(s.emote ?? "(x_x)")
                    .font(Typeface.display(56))
                    .foregroundStyle(s.frame == 1 ? Token.signal : Token.foreground)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder private func emote(_ s: Aftershock.Shock, y: CGFloat) -> some View {
        if let e = s.emote {
            Text(e)
                .font(Typeface.display(s.band > 40 ? 28 : 20))
                .foregroundStyle(Token.foreground)
                .padding(.horizontal, 6)
                .background(Token.background)
                .offset(x: 24 + abs(s.shift) * 2, y: y)
        }
    }
}

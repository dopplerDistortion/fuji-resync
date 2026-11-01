import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ResyncWidgets: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

/// The shooting session on the lock screen and in the Dynamic Island, in the system's dress:
/// black, bone, Geist Mono, a `■` for the link, leaders between label and value.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionAttributes.self) { context in
            LockScreen(context: context)
                .activityBackgroundTint(Token.background)
                .activitySystemActionForegroundColor(Token.foreground)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LinkLine(camera: context.attributes.camera, link: context.state.link)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: context.attributes.startedAt)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Row(label: "geotag", value: geotag(context.state))
                        Row(label: "fired", value: frames(context.state.frames))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Mark(link: context.state.link)
                    Text("\(context.state.geotags)").font(.custom("GeistMono-Medium", size: 13)).monospacedDigit()
                }
                .foregroundStyle(Token.foreground)
            } compactTrailing: {
                // The camera doesn't report its own shots over Bluetooth, so the island shows
                // the session's time rather than a frame count.
                Text(timerInterval: context.attributes.startedAt ... Date.distantFuture, countsDown: false)
                    .font(.custom("GeistMono-Medium", size: 13)).monospacedDigit()
                    .frame(maxWidth: 56)
                    .foregroundStyle(Token.foreground)
            } minimal: {
                Mark(link: context.state.link)
            }
            .keylineTint(Token.foreground)
        }
    }
}

private struct LockScreen: View {
    let context: ActivityViewContext<SessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("RESYNC · SESSION")
                    .font(.custom("GeistMono-Medium", size: 11)).tracking(0.9)
                    .foregroundStyle(Token.mutedForeground)
                Spacer()
                Elapsed(since: context.attributes.startedAt)
            }
            if context.isStale {
                HStack(spacing: 6) {
                    Text("■").font(.system(size: 10)).foregroundStyle(Token.signal)
                    Text("resync stopped · open it to resume")
                        .font(.custom("GeistMono-Regular", size: 14))
                        .foregroundStyle(Token.mutedForeground)
                }
            } else {
                LinkLine(camera: context.attributes.camera, link: context.state.link)
            }
            Rectangle().fill(Token.border).frame(height: 1)
            Row(label: "geotag", value: geotag(context.state))
            Row(label: "sent", value: "\(context.state.geotags)")
            Row(label: "fired", value: frames(context.state.frames))
        }
        .padding(16)
        .foregroundStyle(Token.foreground)
    }
}

/// `■ x-t30 ii · linked`: bone when linked, grey while searching, red when the link is lost.
private struct LinkLine: View {
    var camera: String
    var link: SessionAttributes.ContentState.Link

    var body: some View {
        HStack(spacing: 6) {
            Mark(link: link)
            Text("\(camera) · \(word)")
                .font(.custom("GeistMono-Regular", size: 14))
                .foregroundStyle(link == .linked ? Token.foreground : Token.mutedForeground)
                .lineLimit(1)
        }
    }

    private var word: String {
        switch link {
        case .linked: return "linked"
        case .searching: return "reconnecting"
        case .lost: return "not in range"
        }
    }
}

private struct Mark: View {
    var link: SessionAttributes.ContentState.Link

    var body: some View {
        Text("■")
            .font(.system(size: 10))
            .foregroundStyle(link == .linked ? Token.foreground : (link == .lost ? Token.signal : Token.mark))
    }
}

private struct Elapsed: View {
    var since: Date

    var body: some View {
        Text(timerInterval: since ... Date.distantFuture, countsDown: false)
            .font(.custom("GeistMono-Medium", size: 14)).monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 96, alignment: .trailing)
            .foregroundStyle(Token.foreground)
    }
}

/// `label ┄┄┄┄┄┄ value`
private struct Row: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Token.mutedForeground)
            DottedRule().stroke(Token.mark, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .frame(height: 1)
            Text(value).foregroundStyle(Token.foreground).lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .font(.custom("GeistMono-Regular", size: 13))
    }
}

private struct DottedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private func frames(_ n: Int) -> String { String(format: "%04d", n) }

private func geotag(_ s: SessionAttributes.ContentState) -> String {
    guard s.geotagOn else { return "off" }
    guard let t = s.lastGeotag else { return "waiting for the camera" }
    let time = t.formatted(date: .omitted, time: .shortened).lowercased()
    return time + (s.accuracy.map { " · ±\($0)m" } ?? "")
}

import SwiftUI
import StoreKit

/// resync pro, inline where a locked action is: what it unlocks, the plans, restore, and the
/// links Apple requires next to a subscription. Never a separate screen, so nothing stacks on
/// a sheet that's already open.
struct ProPanel: View {
    /// Why it showed up, in one line: "c4 needs resync pro."
    var reason: String?
    @Environment(Entitlements.self) private var entitlements

    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://dopplerdistortion.github.io/fuji-resync/privacy.html")!

    var body: some View {
        Panel(title: "resync pro", meta: entitlements.isSubscriber ? "active" : "subscription") {
            VStack(alignment: .leading, spacing: 12) {
                if let reason {
                    Text(reason).font(Typeface.body(13)).foregroundStyle(Token.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    line("write c1–c7, not just c1")
                    line("restore any backup to any slot")
                    line("sync and social, as they arrive")
                }
                if entitlements.isSubscriber {
                    Text(status).font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                } else if entitlements.products.isEmpty {
                    HStack(spacing: 8) {
                        BlinkMark()
                        Text("asking the app store").font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                    }
                    .task { await entitlements.loadProducts() }
                } else {
                    ForEach(entitlements.products, id: \.id) { p in
                        FXButton(p.perPeriod, p.subscription?.subscriptionPeriod.unit == .year ? .signal : .default, grow: true, haptic: .medium) {
                            Task { await entitlements.buy(p) }
                        }
                        .disabled(entitlements.busy)
                        .accessibilityIdentifier("pro.buy")
                    }
                }
                if let error = entitlements.lastError {
                    Text(error).font(Typeface.body(12)).foregroundStyle(Token.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("renews until you cancel in settings › apple id › subscriptions. payment goes to your apple id.")
                    .font(Typeface.body(11)).foregroundStyle(Token.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if !entitlements.isSubscriber {
                        FXButton("restore purchases", .ghost, compact: true, haptic: .selection) {
                            Task { await entitlements.restore() }
                        }
                        .disabled(entitlements.busy)
                    }
                    Spacer(minLength: 0)
                    Link("terms", destination: Self.terms).font(Typeface.body(12))
                    Text("·").foregroundStyle(Token.mark)
                    Link("privacy", destination: Self.privacy).font(Typeface.body(12))
                }
            }
            .padding(14)
        }
        .accessibilityIdentifier("pro.panel")
    }

    private var status: String {
        guard let e = entitlements.expires else { return "active" }
        let date = e.formatted(date: .abbreviated, time: .omitted).lowercased()
        return entitlements.willRenew ? "renews \(date)" : "ends \(date)"
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(">").foregroundStyle(Token.mark)
            Text(text).foregroundStyle(Token.foreground)
        }
        .font(Typeface.body(13))
    }
}

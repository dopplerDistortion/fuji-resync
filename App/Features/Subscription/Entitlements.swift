import Foundation
import Observation
import StoreKit
import FujiKit

/// The subscription, as the rest of the app sees it. Features ask this ("can I write c4?")
/// and never talk to StoreKit themselves.
///
/// StoreKit 2 keeps verified transactions on the device, so `currentEntitlements` answers
/// offline. The last answer is also cached, so the gate is right from the first frame.
@MainActor
@Observable
final class Entitlements {
    /// Set up in App Store Connect under one subscription group, "resync pro".
    /// `Config/Resync.storekit` mirrors them for local testing.
    static let productIDs = ["ing.goksen.resync.pro.monthly", "ing.goksen.resync.pro.yearly"]

    private(set) var tier: Tier
    private(set) var products: [Product] = []
    private(set) var expires: Date?
    private(set) var willRenew = true
    private(set) var busy = false
    var lastError: String?

    var isSubscriber: Bool { tier == .subscriber }

    @ObservationIgnored private var updates: Task<Void, Never>?
    private let fake: Bool

    init() {
        if UITest.isOn {
            fake = true
            tier = UITest.pro ? .subscriber : .free
            return
        }
        fake = false
        tier = Tier(rawValue: UserDefaults.standard.string(forKey: "tier") ?? "") ?? .free
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case let .verified(t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { [weak self] in
            await self?.refresh()
            await self?.loadProducts()
        }
    }

    func canWrite(slot: Int) -> Bool { Access.canWrite(slot: slot, tier: tier) }

    func canRestore(slot: Int, from backup: CameraBackup, toCamera serial: String?) -> Bool {
        Access.canRestore(slot: slot, from: backup, toCamera: serial, tier: tier)
    }

    /// Reads the active subscription from StoreKit's verified transactions.
    func refresh() async {
        guard !fake else { return }
        var active = false
        var latest: Date?
        var renews = true
        for await result in Transaction.currentEntitlements {
            guard case let .verified(t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil else { continue }
            if let e = t.expirationDate, e < Date() { continue }
            active = true
            if let e = t.expirationDate, latest.map({ e > $0 }) ?? true { latest = e }
        }
        if active, let status = try? await products.first?.subscription?.status.first {
            if case let .verified(info) = status.renewalInfo { renews = info.willAutoRenew }
        }
        let next: Tier = active ? .subscriber : .free
        if next != tier { AppLog.write(.store, "tier \(tier.rawValue) → \(next.rawValue)") }
        tier = next
        expires = latest
        willRenew = renews
        UserDefaults.standard.set(next.rawValue, forKey: "tier")
    }

    func loadProducts() async {
        guard !fake, products.isEmpty else { return }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            AppLog.write(.store, "loaded \(products.count) products")
        } catch {
            AppLog.write(.store, "couldn't load products: \(error.localizedDescription)")
        }
    }

    /// Buys a product. True when the subscription is active afterwards.
    @discardableResult
    func buy(_ product: Product) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            switch try await product.purchase() {
            case let .success(.verified(t)):
                await t.finish()
                await refresh()
                AppLog.write(.store, "bought \(t.productID)")
                return isSubscriber
            case .success(.unverified):
                lastError = "the app store couldn't verify the purchase."
            case .pending:
                lastError = "the purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription.lowercased()
            AppLog.write(.store, "purchase failed: \(error.localizedDescription)")
        }
        return false
    }

    /// "Restore purchases": asks the App Store for this Apple ID's transactions again.
    func restore() async {
        guard !fake else { return }
        busy = true
        defer { busy = false }
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription.lowercased() }
        await refresh()
    }
}

extension Product {
    /// "2.99 / month" in the user's currency.
    var perPeriod: String {
        guard let p = subscription?.subscriptionPeriod else { return displayPrice }
        let unit: String
        switch p.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return p.value == 1 ? "\(displayPrice) / \(unit)" : "\(displayPrice) / \(p.value) \(unit)s"
    }
}

import UIKit
import SwiftUI
import UserNotifications
import FujiKit

/// Camera work that needs the USB cable: writes to C1–C7 and the pull. Items wait until a
/// camera is ready, then run in order. One open write per slot: a newer one replaces it.
@MainActor
@Observable
final class SendQueue {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case write(Recipe, slot: Int)
            case pull
        }

        enum State: Equatable {
            case waiting, running
            case done(String)
            case failed(String, retry: Bool)
        }

        let id = UUID()
        var kind: Kind
        var state: State = .waiting
        var lines: [String] = []
        var added = Date()

        var title: String {
            switch kind {
            case let .write(r, slot): return "\(r.name.lowercased()) → c\(slot)"
            case .pull: return "pull c1–c7 → library"
            }
        }

        var slot: Int? { if case let .write(_, s) = kind { return s } else { return nil } }
        var recipeID: UUID? { if case let .write(r, _) = kind { return r.id } else { return nil } }

        /// Still owes the camera something: waiting, running, or failed in a way a retry fixes.
        var isOpen: Bool {
            switch state {
            case .waiting, .running: return true
            case let .failed(_, retry): return retry
            case .done: return false
            }
        }

        var status: String {
            switch state {
            case .waiting: return "waiting for cable"
            case .running: return slot.map { "writing c\($0)" } ?? "reading c1–c7"
            case let .done(s): return s
            case let .failed(s, _): return s
            }
        }
    }

    private(set) var items: [Item] = []
    /// Bumps each time there's new work, so the app can drain or wake the USB browser.
    private(set) var kick = 0
    @ObservationIgnored private var draining = false

    var open: [Item] { items.filter(\.isOpen) }

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// The slot a recipe is queued for, for the dashed slot badge.
    func queuedSlot(for recipe: Recipe) -> Int? {
        open.first { $0.recipeID == recipe.id && $0.state != .running }?.slot
    }

    @discardableResult
    func write(_ recipe: Recipe, to slot: Int) -> UUID {
        items.removeAll { $0.slot == slot && $0.isOpen && $0.state != .running }
        let item = Item(kind: .write(recipe.normalized(), slot: slot))
        items.append(item)
        AppLog.write(.usb, "queued \(item.title)")
        askForNotifications()
        kick += 1
        return item.id
    }

    /// The one action from camera to library. Asking twice doesn't queue twice.
    @discardableResult
    func pull() -> UUID {
        if let existing = open.first(where: { $0.kind == .pull }) { return existing.id }
        let item = Item(kind: .pull)
        items.append(item)
        kick += 1
        return item.id
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id && $0.state != .running }
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .waiting
        items[i].lines = []
        kick += 1
    }

    func clearFinished() {
        items.removeAll { !$0.isOpen }
    }

    /// Runs every waiting item (and each retryable failure once) while the camera stays ready.
    func drain(usb: USBCameraController, store: RecipeStore, overlays: Overlays) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        let ids = items.filter(\.isOpen).map(\.id)
        var finished: [Item] = []
        for id in ids {
            guard usb.isReady, let i = items.firstIndex(where: { $0.id == id }), items[i].isOpen else { continue }
            items[i].state = .running
            let kind = items[i].kind
            let (state, lines) = await run(kind, usb: usb, store: store)
            guard let j = items.firstIndex(where: { $0.id == id }) else { continue }
            items[j].state = state
            items[j].lines = lines
            finished.append(items[j])
        }
        if items.count > 12 {
            let closed = items.filter { !$0.isOpen }.prefix(items.count - 12).map(\.id)
            items.removeAll { closed.contains($0.id) }
        }
        report(finished, overlays: overlays)
    }

    private func run(_ kind: Item.Kind, usb: USBCameraController, store: RecipeStore) async -> (Item.State, [String]) {
        switch kind {
        case let .write(recipe, slot):
            guard let report = await usb.write(recipe, to: slot) else {
                return (.failed("the camera stopped answering · retries when it's back", retry: true), [])
            }
            if report.ok {
                return (.done("wrote \(report.written) settings · read back"), [])
            }
            return (.failed("the camera rejected \(report.rejected.count) setting\(report.rejected.count == 1 ? "" : "s")", retry: false),
                    report.rejected.map { "✕ \($0.lowercased())" })
        case .pull:
            await usb.refreshSlots()
            guard usb.isReady, !usb.slots.isEmpty else {
                return (.failed("couldn't read the camera · retries when it's back", retry: true), [])
            }
            let lines = usb.slots.sorted { $0.slot < $1.slot }.map { p -> String in
                let r = PresetCodec.decode(p)
                let name = (p.name.isEmpty ? "unnamed" : p.name).lowercased()
                return store.libraryMatch(for: r) == nil ? "c\(p.slot) \(name) · new · saved" : "c\(p.slot) \(name) · already there"
            }
            let r = store.saveAllFromCamera(usb.slots)
            return (.done(PullNote.text(r)), lines)
        }
    }

    private func report(_ done: [Item], overlays: Overlays) {
        guard !done.isEmpty else { return }
        let failed = done.filter { if case .failed = $0.state { return true } else { return false } }
        let text: String
        let detail: String?
        if done.count == 1, let one = done.first {
            text = one.kind == .pull ? "pulled c1–c7" : (failed.isEmpty ? "c\(one.slot ?? 0) written" : "c\(one.slot ?? 0) not written")
            detail = one.status
        } else {
            text = "sent \(done.count - failed.count) of \(done.count)"
            detail = failed.isEmpty ? "every slot read back" : failed.map(\.title).joined(separator: ", ")
        }
        Haptic.play(failed.isEmpty ? .success : .error)
        if UIApplication.shared.applicationState == .active {
            overlays.toast(text, detail: detail, duration: failed.isEmpty ? 3.5 : 6)
        } else {
            let content = UNMutableNotificationContent()
            content.title = text
            content.body = detail ?? ""
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    @ObservationIgnored private var askedForNotifications = false

    /// Queued writes can finish with the app in the background; ask once, the first time one is queued.
    private func askForNotifications() {
        guard !askedForNotifications, !UITest.isOn else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

enum PullNote {
    static func text(_ r: (added: Int, already: Int)?) -> String {
        guard let r else { return "couldn't read the camera. check the cable and try again." }
        if r.added == 0 { return "all \(r.already) slots already in the library" }
        return "saved \(r.added) new · \(r.already) already there"
    }
}

/// The system share sheet, for things that can't be a `ShareLink` (menu items, files written on demand).
enum ShareSheet {
    @MainActor
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.overrideUserInterfaceStyle = .dark
        vc.view.tintColor = UIColor(Token.foreground)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        }
        top.present(vc, animated: true)
    }

    /// Writes data to a temporary file with this name, so the share sheet offers it as a file.
    static func file(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

import SwiftUI
import FujiKit

/// One backup of c1–c7: what each slot held, and putting slots back. Restores go through the
/// queue like any send, so they wait for the cable and read back.
struct BackupDetail: View {
    var backup: CameraBackup
    var close: () -> Void
    @Environment(BackupStore.self) private var backups
    @Environment(RecipeStore.self) private var store
    @Environment(SendQueue.self) private var queue
    @Environment(USBCameraController.self) private var usb
    @Environment(Entitlements.self) private var entitlements
    @Environment(Overlays.self) private var overlays
    /// Confirmations happen in the sheet: the app's overlays sit under it. One tap arms, the next runs.
    @State private var armed: String?
    @State private var queued: Set<Int> = []

    var body: some View {
        let allowed = Access.restorableSlots(of: backup, toCamera: usb.serial, tier: entitlements.tier)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Panel(title: "c1–c7", meta: backup.origin == .imported ? "imported" : "this camera") {
                    VStack(spacing: 0) {
                        ForEach(backup.slots, id: \.slot) { s in
                            slotRow(s, allowed: allowed.contains(s.slot))
                        }
                    }
                }
                if allowed.count < backup.slots.count, !entitlements.isSubscriber {
                    ProPanel(reason: backup.origin == .imported
                             ? "the free plan restores c1 from a shared backup. resync pro restores every slot."
                             : "this backup is from another camera. the free plan restores c1 from it.")
                }
                if armed == "all" {
                    Text("resync keeps what's on the camera now as a backup first. the camera can't undo a write, but that backup can.")
                        .font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FXButton(armed == "all" ? "tap again to restore" : restoreAllLabel(allowed), .signal, grow: true, haptic: .medium) {
                    guard armed == "all" else { armed = "all"; return }
                    for n in allowed { if let s = backup.slot(n) { queue.write(s.restorable, to: n, restore: true) } }
                    close()
                    overlays.toast(usb.isReady ? "restoring \(allowed.count) slots" : "queued \(allowed.count) slots · plug in")
                }
                .disabled(allowed.isEmpty)
                .accessibilityIdentifier("backup.restoreAll")
                HStack {
                    FXButton("export", .outline, compact: true) {
                        if let url = ShareSheet.file(backups.exportData(backup), name: backup.fileName) { ShareSheet.present([url]) }
                    }
                    Spacer()
                    if backups.latest?.id != backup.id {
                        FXButton(armed == "delete" ? "tap again to delete" : "delete", .ghost, compact: true, haptic: .selection) {
                            guard armed == "delete" else { armed = "delete"; return }
                            backups.delete(backup.id)
                            close()
                        }
                    }
                }
            }
            .padding(.horizontal, Token.gutter)
            .padding(.bottom, 20)
        }
    }

    private func restoreAllLabel(_ allowed: [Int]) -> String {
        let what = allowed.count == backup.slots.count ? "c1–c7" : allowed.map { "c\($0)" }.joined(separator: ", ")
        return (usb.isReady ? "restore " : "queue restore of ") + what
    }

    private func slotRow(_ s: CameraBackup.Slot, allowed: Bool) -> some View {
        let name = (s.name.isEmpty ? "unnamed" : s.name).lowercased()
        let match = store.libraryMatch(for: s.recipe)
        return HStack(spacing: 10) {
            Text("C\(s.slot)").font(Typeface.medium(10)).tracking(0.6)
                .frame(minWidth: 26, minHeight: 20)
                .overlay(Rectangle().strokeBorder(Token.foreground, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Typeface.body(15)).lineLimit(1)
                Text(s.recipe.filmSimulation.label.lowercased() + (match == nil ? " · not in library" : ""))
                    .font(Typeface.body(11)).foregroundStyle(Token.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 8)
            if queued.contains(s.slot) {
                Text(usb.isReady ? "restoring" : "queued").font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
            } else if allowed {
                FXButton(armed == "c\(s.slot)" ? "sure?" : "restore", .outline, compact: true) {
                    guard armed == "c\(s.slot)" else { armed = "c\(s.slot)"; return }
                    queue.write(s.restorable, to: s.slot, restore: true)
                    queued.insert(s.slot)
                    armed = nil
                }
                .accessibilityIdentifier("backup.restore.c\(s.slot)")
            } else {
                Text("pro").font(Typeface.body(12)).foregroundStyle(Token.mutedForeground)
                    .accessibilityLabel("needs resync pro")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }
}

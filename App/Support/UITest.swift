import Foundation

/// Launch flags for the UI tests (`UITests/`). With `-uitest` the app uses its own library file,
/// starts from the starter recipes, pretends C1–C5 were read from the camera, skips the boot
/// screen and asks for no permissions. `-uitest-fresh` shows the boot screen instead.
enum UITest {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-uitest")
    static let fresh = ProcessInfo.processInfo.arguments.contains("-uitest-fresh")
    /// Runs as a subscriber. Without it a UI test sees the free tier: C1 only.
    static let pro = ProcessInfo.processInfo.arguments.contains("-uitest-pro")

    /// The backups file for this launch, deleted first under test like the library.
    static func backupsFilename() -> String {
        guard isOn else { return "backups.json" }
        let name = "uitest-backups.json"
        if let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return name
    }

    /// The library file for this launch. Under test it's deleted first, so every run starts clean.
    static func storeFilename() -> String {
        guard isOn else { return "recipes.json" }
        let name = "uitest-recipes.json"
        if let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        UserDefaults.standard.set(!fresh, forKey: "booted")
        return name
    }
}

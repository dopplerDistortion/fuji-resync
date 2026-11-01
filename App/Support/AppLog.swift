import Foundation
import os

/// Persistent app log: every controller line goes to the unified log (Console.app, subsystem
/// `ing.goksen.resync`) and to `Documents/resync.log`.
///
/// Pull the file over USB from a Mac:
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
///  --domain-identifier ing.goksen.resync --source Documents/resync.log --destination resync.log`
/// It is also visible in the Files app (On My iPhone → resync) and can be shared from about.
enum AppLog {
    enum Category: String { case app, usb, ble, wifi, recipes }

    static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("resync.log")
    }()

    private static let queue = DispatchQueue(label: "resync.log")
    private static let maxBytes = 2_000_000
    private static let loggers: [Category: Logger] = {
        var out: [Category: Logger] = [:]
        for c in [Category.app, .usb, .ble, .wifi, .recipes] {
            out[c] = Logger(subsystem: "ing.goksen.resync", category: c.rawValue)
        }
        return out
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ category: Category, _ message: String) {
        loggers[category]?.notice("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) [\(category.rawValue)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func session() {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        write(.app, "--- launch resync \(v) (\(b)) · iOS \(os)")
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    static func contents() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }
}

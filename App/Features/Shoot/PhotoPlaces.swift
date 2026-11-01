import Foundation
import ImageIO
import CoreLocation

/// Where a photo on the camera was taken, read from its EXIF GPS over USB.
struct PhotoPlace: Codable, Hashable, Identifiable {
    var id: String { file + "@" + String(taken?.timeIntervalSince1970 ?? 0) }
    var file: String
    var taken: Date?
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Reads `{GPS}` and `{Exif}.DateTimeOriginal` from an ImageIO metadata dictionary.
    static func from(file: String, metadata: [AnyHashable: Any]?) -> PhotoPlace? {
        guard let meta = metadata,
              let gps = meta[kCGImagePropertyGPSDictionary as String] as? [AnyHashable: Any],
              var lat = number(gps[kCGImagePropertyGPSLatitude as String]),
              var lon = number(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W" { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        return PhotoPlace(file: file.lowercased(), taken: takenDate(metadata: meta), latitude: lat, longitude: lon)
    }

    /// `{Exif}.DateTimeOriginal`, in the camera's clock (read in the phone's time zone).
    static func takenDate(metadata: [AnyHashable: Any]?) -> Date? {
        guard let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [AnyHashable: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        return exifDate.date(from: s)
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}

/// Every photo location read from the camera, kept on the phone so the map shows them without
/// the cable. Files already read (with or without GPS) are not read again.
@MainActor
@Observable
final class PhotoPlaces {
    /// A location resync sent the camera: it asks every few seconds while linked, so these trail
    /// where the camera was, even before the card is read.
    struct Sent: Codable, Hashable {
        var at: Date
        var latitude: Double
        var longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    private(set) var places: [PhotoPlace] = []
    private(set) var sent: [Sent] = []
    private(set) var readAt: Date?
    @ObservationIgnored private(set) var checked: Set<String> = []
    /// When each photo read from the card was taken, with or without GPS: it counts the
    /// photos of a shooting session, which Bluetooth can't report.
    private(set) var shots: [String: Date] = [:]

    private struct Saved: Codable {
        var places: [PhotoPlace]
        var checked: [String]
        var readAt: Date?
        var sent: [Sent]?
        /// 3: files are marked read only when their read worked, and a file with no GPS in its
        /// metadata has its header read too. Lists saved before that are dropped, so the photos
        /// they marked are read again.
        var version: Int?
        var shots: [String: Date]?
    }

    private let url: URL

    init(filename: String = "photo-places.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            places = saved.places
            checked = (saved.version ?? 1) >= 3 ? Set(saved.checked) : []
            readAt = saved.readAt
            sent = saved.sent ?? []
            shots = (saved.version ?? 1) >= 3 ? saved.shots ?? [:] : [:]
        }
    }

    func merge(_ found: [PhotoPlace], checked names: Set<String>, taken: [String: Date] = [:]) {
        checked.formUnion(names)
        shots.merge(taken) { _, new in new }
        var byID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in found { byID[p.id] = p }
        places = byID.values.sorted { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
        readAt = Date()
        save()
    }

    /// Keeps a sent geotag unless it repeats the last one within 15 m and a minute.
    func record(_ loc: CLLocation) {
        if let last = sent.last {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude).distance(from: loc)
            if d < 15, loc.timestamp.timeIntervalSince(last.at) < 60 { return }
        }
        sent.append(Sent(at: Date(), latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
        if sent.count > 2000 { sent.removeFirst(sent.count - 2000) }
        save()
    }

    /// Photos on the card taken between `start` and `end`, give or take a minute for the
    /// camera's clock.
    func shotCount(from start: Date, to end: Date) -> Int {
        let a = start.addingTimeInterval(-60), b = end.addingTimeInterval(60)
        return shots.values.filter { $0 >= a && $0 <= b }.count
    }

    #if DEBUG
    /// A few pins for the UI tests and the simulator, which has no camera.
    func seedForUITests() {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        places = [
            PhotoPlace(file: "dscf0101.jpg", taken: base, latitude: 41.0256, longitude: 28.9744),
            PhotoPlace(file: "dscf0102.jpg", taken: base.addingTimeInterval(600), latitude: 41.0262, longitude: 28.9787),
            PhotoPlace(file: "dscf0108.jpg", taken: base.addingTimeInterval(3600), latitude: 41.0369, longitude: 28.9850),
        ]
        readAt = base.addingTimeInterval(4000)
    }
    #endif

    private func save() {
        let saved = Saved(places: places, checked: Array(checked), readAt: readAt, sent: sent, version: 3, shots: shots)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }
}

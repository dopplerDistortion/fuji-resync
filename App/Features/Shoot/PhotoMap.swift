import MapKit
import SwiftUI

/// Where the photos on the card were taken: on your Mapbox style when a token is set, else on
/// Apple's map in greyscale. The pins and chips are ours: a bone square per place (a count when several photos
/// share it) and a small hollow square for each location resync sent the camera.
struct PhotoMap: View {
    var dimmed: Bool
    @Environment(PhotoPlaces.self) private var places
    @Environment(USBCameraController.self) private var usb
    @State private var picked: String?
    @State private var centre: CLLocationCoordinate2D?
    /// Bumped to frame every pin again.
    @State private var fitTick = 0

    var body: some View {
        let pins = Pin.group(places.places)
        let trail = places.sent.suffix(300).map(\.coordinate)
        let fit = PhotoMapFit(coordinates: places.places.map(\.coordinate) + trail)
        ZStack(alignment: .topLeading) {
            Group {
                if MapboxSetup.isOn {
                    MapboxPhotoLayer(pins: pins, trail: trail, fit: fit, fitTick: fitTick,
                                     picked: $picked, centre: $centre)
                } else {
                    ApplePhotoLayer(pins: pins, trail: trail, fit: fit, fitTick: fitTick,
                                    picked: $picked, centre: $centre)
                }
            }
            .opacity(dimmed ? 0.2 : 1)
            .allowsHitTesting(!dimmed)
            .accessibilityIdentifier("map")

            if !dimmed { chips(pins) }
        }
        .transaction { $0.animation = nil }
        // Listen for the cable from here too, so plugging in on the shoot tab fills the map.
        .onAppear { usb.start() }
        .onChange(of: places.places.count) { _, _ in fitTick += 1 }
    }

    private func chips(_ pins: [Pin]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("■")
                    Text((places.places.isEmpty ? "map · no photos pinned" : "map · \(places.places.count) photos")
                        + (places.sent.isEmpty ? "" : " · □ \(places.sent.count) geotags"))
                }
                .chip(lit: false)
                Spacer(minLength: 0)
                if !places.places.isEmpty || !places.sent.isEmpty {
                    Button {
                        fitTick += 1
                        picked = nil
                        Haptic.play(.selection)
                    } label: { Text("fit").chip(lit: false) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("fit every pin")
                }
            }
            if places.places.isEmpty {
                Text(places.readAt == nil
                     ? "plug the camera in, in usb card reader mode, to pin where its photos were taken. □ marks where the phone sent the camera its location."
                     : "card read \(places.checked.count) photos, none with a location. a photo gets one when the camera is linked as you shoot.")
                    .font(Typeface.body(12))
                    .foregroundStyle(Token.mutedForeground)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Token.background)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let at = places.readAt {
                Text("card read " + at.formatted(date: .abbreviated, time: .shortened).lowercased())
                    .font(Typeface.body(11))
                    .foregroundStyle(Token.mutedForeground)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Token.background)
            }
        }
        .padding(8)
    }
}

/// The pins' extent. Each map frames it with room around it, and more room at the bottom, so no
/// pin lands under the centred live view button.
struct PhotoMapFit: Equatable {
    var minLat = 0.0, maxLat = 0.0, minLon = 0.0, maxLon = 0.0
    var coordinates: [CLLocationCoordinate2D] = []

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        guard let first = coordinates.first else { return }
        minLat = first.latitude; maxLat = first.latitude; minLon = first.longitude; maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
    }

    var isEmpty: Bool { coordinates.isEmpty }

    static func == (a: Self, b: Self) -> Bool {
        a.coordinates.count == b.coordinates.count && a.minLat == b.minLat && a.maxLat == b.maxLat
            && a.minLon == b.minLon && a.maxLon == b.maxLon
    }

    /// Apple's map: 1.8× and 1.5× the extent, with the centre moved south so the pins sit in the
    /// upper two thirds.
    var region: MKCoordinateRegion? {
        guard !isEmpty else { return nil }
        let latSpan = max(maxLat - minLat, 0.004)
        let lonSpan = max(maxLon - minLon, 0.004)
        let span = MKCoordinateSpan(latitudeDelta: latSpan * 1.8, longitudeDelta: lonSpan * 1.5)
        let centre = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 - latSpan * 0.3, longitude: (minLon + maxLon) / 2)
        return MKCoordinateRegion(center: centre, span: span)
    }
}

/// Apple's map, dark, muted and greyscale with no points of interest: the map when no Mapbox
/// token is set, as on CI.
private struct ApplePhotoLayer: View {
    var pins: [Pin]
    var trail: [CLLocationCoordinate2D]
    var fit: PhotoMapFit
    var fitTick: Int
    @Binding var picked: String?
    @Binding var centre: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(Array(trail.enumerated()), id: \.offset) { _, c in
                Annotation("", coordinate: c, anchor: .center) { TrailMark() }
                    .annotationTitles(.hidden)
            }
            ForEach(pins) { pin in
                Annotation("", coordinate: pin.coordinate, anchor: .center) {
                    PinButton(pin: pin, picked: $picked, centre: centre)
                }
                .annotationTitles(.hidden)
            }
            UserAnnotation { UserMark() }
        }
        // Fit keeps clear of our chips above; the legal label sits low at the left, beside the
        // centred live view button.
        .safeAreaPadding(.top, 52)
        .safeAreaPadding(.bottom, 8)
        .safeAreaPadding(.horizontal, 12)
        .onMapCameraChange { ctx in centre = ctx.region.center }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .environment(\.colorScheme, .dark)
        .saturation(0)
        .onAppear { position = fit.region.map { .region($0) } ?? .automatic }
        .onChange(of: fitTick) { _, _ in position = fit.region.map { .region($0) } ?? .automatic }
    }
}

/// A small hollow square for each location resync sent the camera.
struct TrailMark: View {
    var body: some View {
        Rectangle().strokeBorder(Token.mutedForeground, lineWidth: 1)
            .frame(width: 5, height: 5)
            .allowsHitTesting(false)
    }
}

/// Where the phone is: a bone outline with a bone dot.
struct UserMark: View {
    var body: some View {
        Rectangle().strokeBorder(Token.foreground, lineWidth: 1)
            .frame(width: 12, height: 12)
            .overlay(Rectangle().fill(Token.foreground).frame(width: 4, height: 4))
    }
}

/// A pin that shows its file and time when tapped.
struct PinButton: View {
    var pin: Pin
    @Binding var picked: String?
    var centre: CLLocationCoordinate2D?

    var body: some View {
        PinMark(count: pin.photos.count, lit: picked == pin.id, label: picked == pin.id ? pin.label : nil,
                // The tag runs toward the middle of the map, so it stays on screen.
                tagRunsLeft: pin.coordinate.longitude > (centre?.longitude ?? pin.coordinate.longitude),
                // In the upper half the tag hangs below the pin, clear of the chips at the top.
                tagBelow: pin.coordinate.latitude > (centre?.latitude ?? pin.coordinate.latitude))
            .onTapGesture {
                picked = picked == pin.id ? nil : pin.id
                Haptic.play(.selection)
            }
            .accessibilityElement()
            .accessibilityLabel(pin.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("map.pin")
    }
}

/// Photos taken within about 100 m of each other share a pin.
struct Pin: Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var photos: [PhotoPlace]

    var label: String {
        let first = photos[0]
        let when = first.taken.map { " · " + $0.formatted(date: .abbreviated, time: .shortened).lowercased() } ?? ""
        return first.file + when + (photos.count > 1 ? " · +\(photos.count - 1)" : "")
    }

    static func group(_ places: [PhotoPlace]) -> [Pin] {
        var buckets: [String: [PhotoPlace]] = [:]
        var order: [String] = []
        for p in places {
            let key = String(format: "%.3f,%.3f", p.latitude, p.longitude)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(p)
        }
        return order.map { key in
            let ps = buckets[key] ?? []
            let lat = ps.map(\.latitude).reduce(0, +) / Double(ps.count)
            let lon = ps.map(\.longitude).reduce(0, +) / Double(ps.count)
            return Pin(id: key, coordinate: .init(latitude: lat, longitude: lon), photos: ps)
        }
    }
}

/// A 10 pt bone square with an ink edge; inverted when picked, with its file and time in a
/// bone tag beside it; the count beside it when several photos share it.
struct PinMark: View {
    var count: Int
    var lit: Bool
    var label: String?
    var tagRunsLeft = false
    var tagBelow = false

    var body: some View {
        // Only the square takes part in layout, so it stays centred on the coordinate; the
        // count and the tag hang off it as overlays.
        Rectangle()
            .fill(lit ? Token.background : Token.foreground)
            .frame(width: 10, height: 10)
            .overlay(Rectangle().strokeBorder(lit ? Token.foreground : Token.ink, lineWidth: 1))
            .overlay(alignment: .leading) {
                if count > 1 {
                    Text("\(count)")
                        .font(Typeface.medium(10))
                        .foregroundStyle(Token.foreground)
                        .padding(.horizontal, 2)
                        .background(Token.background.opacity(0.8))
                        .fixedSize()
                        .offset(x: 13)
                }
            }
            .overlay(alignment: tagBelow ? (tagRunsLeft ? .topTrailing : .topLeading) : (tagRunsLeft ? .bottomTrailing : .bottomLeading)) {
                if let label {
                    Text(label)
                        .font(Typeface.body(11))
                        .foregroundStyle(Token.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Token.foreground)
                        .fixedSize()
                        .offset(y: tagBelow ? 16 : -16)
                        .accessibilityIdentifier("map.picked")
                }
            }
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
    }
}

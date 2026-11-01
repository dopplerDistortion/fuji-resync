import MapKit
import SwiftUI

/// Where the photos on the card were taken, on a dark, muted, greyscale map with no points of
/// interest. The pins and chips are ours: a bone square per place (a count when several photos
/// share it) and a small hollow square for each location resync sent the camera.
struct PhotoMap: View {
    var dimmed: Bool
    @Environment(PhotoPlaces.self) private var places
    @State private var position: MapCameraPosition = .automatic
    @State private var picked: String?

    var body: some View {
        let pins = Pin.group(places.places)
        let trail = Array(places.sent.suffix(300))
        ZStack(alignment: .topLeading) {
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                ForEach(Array(trail.enumerated()), id: \.offset) { _, s in
                    Annotation("", coordinate: s.coordinate, anchor: .center) {
                        Rectangle().strokeBorder(Token.mutedForeground, lineWidth: 1)
                            .frame(width: 5, height: 5)
                            .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(pins) { pin in
                    Annotation("", coordinate: pin.coordinate, anchor: .center) {
                        PinMark(count: pin.photos.count, lit: picked == pin.id, label: picked == pin.id ? pin.label : nil)
                            .onTapGesture {
                                picked = picked == pin.id ? nil : pin.id
                                Haptic.play(.selection)
                            }
                            .accessibilityElement()
                            .accessibilityLabel(pin.label)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("map.pin")
                    }
                    .annotationTitles(.hidden)
                }
                UserAnnotation {
                    Rectangle().strokeBorder(Token.foreground, lineWidth: 1)
                        .frame(width: 12, height: 12)
                        .overlay(Rectangle().fill(Token.foreground).frame(width: 4, height: 4))
                }
            }
            // Fit and the legal label keep clear of our chips above and the live view button below.
            .safeAreaPadding(.top, 52)
            .safeAreaPadding(.bottom, 72)
            .safeAreaPadding(.horizontal, 12)
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .environment(\.colorScheme, .dark)
            .saturation(0)
            .opacity(dimmed ? 0.2 : 1)
            .allowsHitTesting(!dimmed)
            .accessibilityIdentifier("map")

            if !dimmed { chips(pins) }
        }
        .transaction { $0.animation = nil }
    }

    private func chips(_ pins: [Pin]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("■")
                    Text(places.places.isEmpty ? "map · no photo locations yet" : "map · \(places.places.count) photos")
                }
                .chip(lit: false)
                Spacer(minLength: 0)
                if !places.places.isEmpty || !places.sent.isEmpty {
                    Button {
                        position = .automatic
                        picked = nil
                        Haptic.play(.selection)
                    } label: { Text("fit").chip(lit: false) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("fit every pin")
                }
            }
            if places.places.isEmpty {
                Text("plug the camera in once to read where its photos were taken")
                    .font(Typeface.body(12))
                    .foregroundStyle(Token.mutedForeground)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Token.background.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let at = places.readAt {
                Text("card read " + at.formatted(date: .abbreviated, time: .shortened).lowercased())
                    .font(Typeface.body(11))
                    .foregroundStyle(Token.mutedForeground)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Token.background.opacity(0.8))
            }
        }
        .padding(8)
    }
}

/// Photos taken within about 100 m of each other share a pin.
private struct Pin: Identifiable {
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
private struct PinMark: View {
    var count: Int
    var lit: Bool
    var label: String?

    var body: some View {
        HStack(spacing: 3) {
            Rectangle()
                .fill(lit ? Token.background : Token.foreground)
                .frame(width: 10, height: 10)
                .overlay(Rectangle().strokeBorder(lit ? Token.foreground : Token.ink, lineWidth: 1))
            if count > 1 {
                Text("\(count)")
                    .font(Typeface.medium(10))
                    .foregroundStyle(Token.foreground)
                    .padding(.horizontal, 2)
                    .background(Token.background.opacity(0.8))
            }
            if let label {
                Text(label)
                    .font(Typeface.body(11))
                    .foregroundStyle(Token.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Token.foreground)
                    .fixedSize()
                    .accessibilityIdentifier("map.picked")
            }
        }
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
    }
}

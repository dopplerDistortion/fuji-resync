import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// The Mapbox map turns on when the build has a public token: `MAPBOX_ACCESS_TOKEN` in
/// `Config/Local.xcconfig`, which the Info.plist hands Mapbox as `MBXAccessToken`. The style is
/// `MapStyle.json` in the app's resources.
enum MapboxSetup {
    static let style: MapStyle? = {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              token.hasPrefix("pk."),
              let url = Bundle.main.url(forResource: "MapStyle", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MapStyle(json: json)
    }()

    static var isOn: Bool { style != nil }
}

/// The photo map on the Mapbox style, with our own pins, trail and phone mark drawn as SwiftUI
/// views on top. Pan and zoom only: no rotation or tilt, no compass or scale bar. The Mapbox logo
/// and the attribution button stay visible, low in the corners beside the live view button.
struct MapboxPhotoLayer: View {
    var pins: [Pin]
    var trail: [CLLocationCoordinate2D]
    var fit: PhotoMapFit
    var fitTick: Int
    @Binding var picked: String?
    @Binding var centre: CLLocationCoordinate2D?
    @State private var viewport: Viewport = .idle

    var body: some View {
        Map(viewport: $viewport) {
            ForEvery(Array(trail.indices), id: \.self) { i in
                MapViewAnnotation(coordinate: trail[i]) { TrailMark() }
                    .allowOverlap(true)
            }
            ForEvery(pins) { pin in
                MapViewAnnotation(coordinate: pin.coordinate) {
                    PinButton(pin: pin, picked: $picked, centre: centre)
                }
                .allowOverlap(true)
            }
            // The puck asks for location; UI tests run with no permission prompts.
            if !UITest.isOn {
                Puck2D()
                    .topImage(Self.userMark)
                    .bearingImage(nil)
                    .shadowImage(Self.clear)
                    .showsAccuracyRing(false)
            }
        }
        .mapStyle(MapboxSetup.style ?? .dark)
        .gestureOptions(Self.gestures)
        .ornamentOptions(Self.ornaments)
        .onCameraChanged { changed in centre = changed.cameraState.center }
        .onAppear {
            // The ⓘ attribution button in bone, not the system's blue.
            UIButton.appearance(whenContainedInInstancesOf: [MapView.self]).tintColor = UIColor(Token.foreground)
            viewport = framed()
        }
        .onChange(of: fitTick) { _, _ in viewport = framed() }
    }

    /// Every pin with room around it: clear of the chips above and the live view button below.
    private func framed() -> Viewport {
        guard !fit.isEmpty else { return .idle }
        return .overview(geometry: MultiPoint(fit.coordinates),
                         geometryPadding: EdgeInsets(top: 72, leading: 36, bottom: 96, trailing: 36),
                         maxZoom: 15)
    }

    private static var gestures: GestureOptions {
        var g = GestureOptions()
        g.rotateEnabled = false
        g.pitchEnabled = false
        return g
    }

    private static var ornaments: OrnamentOptions {
        OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(visibility: .hidden),
            logo: LogoViewOptions(position: .bottomLeading, margins: CGPoint(x: 8, y: 8)),
            attributionButton: AttributionButtonOptions(position: .bottomTrailing, margins: CGPoint(x: 4, y: 4))
        )
    }

    @MainActor private static let userMark: UIImage? = {
        let r = ImageRenderer(content: UserMark())
        r.scale = UIScreen.main.scale
        return r.uiImage
    }()

    @MainActor private static let clear: UIImage? = {
        let r = ImageRenderer(content: Color.clear.frame(width: 1, height: 1))
        r.scale = 1
        return r.uiImage
    }()
}

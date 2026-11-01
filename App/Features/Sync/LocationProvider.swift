import Foundation
import CoreLocation

/// Keeps a recent location fix while the camera is linked. Low-power: significant changes in the
/// background, ~100 m accuracy in the foreground, which is plenty for geotags.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private var oneShots: [(CLLocation) -> Void] = []
    var onUpdate: ((CLLocation) -> Void)?

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func setActive(_ on: Bool) {
        if on {
            requestPermission()
            manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func requestOneShot(_ done: @escaping (CLLocation) -> Void) {
        oneShots.append(done)
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated {
            latest = loc
            onUpdate?(loc)
            let pending = oneShots; oneShots = []
            pending.forEach { $0(loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}

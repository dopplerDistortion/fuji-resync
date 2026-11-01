import Foundation
import CoreLocation

/// Keeps a recent location fix while the camera is linked. Low-power: significant changes in the
/// background, ~100 m accuracy in the foreground, which is plenty for geotags.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private var oneShots: [(CLLocation) -> Void] = []
    /// Every fix as it arrives, oldest first: a shooting session records its route from these.
    var onFixes: (@MainActor ([CLLocation]) -> Void)?

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

    /// The Bluetooth link wants fixes while it is up.
    private var wanted = false
    /// A shooting session holds location on in the background, with iOS's indicator, at 10 m.
    private var held = false

    func setActive(_ on: Bool) {
        wanted = on
        apply()
    }

    func hold(_ on: Bool) {
        held = on
        apply()
    }

    private func apply() {
        if wanted || held {
            requestPermission()
            manager.allowsBackgroundLocationUpdates = held || manager.authorizationStatus == .authorizedAlways
            manager.showsBackgroundLocationIndicator = held
            manager.desiredAccuracy = held ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
            manager.distanceFilter = held ? 10 : 50
            manager.pausesLocationUpdatesAutomatically = !held
            // A session is someone walking about with the camera; fitness keeps the fixes on paths.
            manager.activityType = held ? .fitness : .other
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
            onFixes?(locations)
            let pending = oneShots; oneShots = []
            pending.forEach { $0(loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.write(.ble, "location error: \(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        AppLog.write(.ble, "location authorization: \(manager.authorizationStatus.rawValue)")
    }
}

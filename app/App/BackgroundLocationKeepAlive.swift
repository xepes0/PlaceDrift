import CoreLocation
import Foundation

@MainActor
final class BackgroundLocationKeepAlive: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State: String, Sendable {
        case idle
        case requestingAlwaysAuthorization
        case needsAlwaysAuthorization
        case active
        case denied
        case restricted
        case servicesDisabled
        case failed
        case stopped
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private let manager = CLLocationManager()
    private var requested = false
    private var requestedAlwaysUpgrade = false
    private var authorizationOnly = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
        manager.activityType = .other
    }

    func requestInitialAuthorization() {
        guard CLLocationManager.locationServicesEnabled() else {
            update(.servicesDisabled)
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            requested = true
            authorizationOnly = true
            requestedAlwaysUpgrade = false
            update(.requestingAlwaysAuthorization)
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            requested = true
            authorizationOnly = true
            update(.needsAlwaysAuthorization)
            if !requestedAlwaysUpgrade {
                requestedAlwaysUpgrade = true
                manager.requestAlwaysAuthorization()
            }

        case .authorizedAlways:
            update(.stopped)

        case .denied:
            update(.denied)

        case .restricted:
            update(.restricted)

        @unknown default:
            update(.failed)
        }
    }

    func start() {
        authorizationOnly = false
        requested = true
        reconcileAuthorization()
    }

    func stop() {
        requested = false
        authorizationOnly = false
        requestedAlwaysUpgrade = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        update(.stopped)
    }

    private func update(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func reconcileAuthorization() {
        guard requested else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            update(.servicesDisabled)
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            update(.requestingAlwaysAuthorization)
            if authorizationOnly {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestAlwaysAuthorization()
            }

        case .authorizedWhenInUse:
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            update(.needsAlwaysAuthorization)
            if !requestedAlwaysUpgrade {
                requestedAlwaysUpgrade = true
                manager.requestAlwaysAuthorization()
            }

        case .authorizedAlways:
            if authorizationOnly {
                requested = false
                authorizationOnly = false
                requestedAlwaysUpgrade = false
                manager.stopUpdatingLocation()
                manager.allowsBackgroundLocationUpdates = false
                update(.stopped)
            } else {
                manager.showsBackgroundLocationIndicator = false
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
                update(.active)
            }

        case .denied:
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            update(.denied)

        case .restricted:
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            update(.restricted)

        @unknown default:
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            update(.failed)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reconcileAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requested else { return }
        if (error as? CLError)?.code == .denied {
            update(CLLocationManager.locationServicesEnabled() ? .denied : .servicesDisabled)
        }
    }
}

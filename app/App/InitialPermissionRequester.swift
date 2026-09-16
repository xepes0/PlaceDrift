import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class InitialPermissionRequester: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private static let whenInUseRequestKey = "placedrift.permissions.when-in-use-requested"
    private static let alwaysRequestKey = "placedrift.permissions.always-requested"

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestIfNeeded() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch manager.authorizationStatus {
        case .notDetermined:
            guard !UserDefaults.standard.bool(forKey: Self.whenInUseRequestKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.whenInUseRequestKey)
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            requestAlwaysIfNeeded()

        case .authorizedAlways, .denied, .restricted:
            break

        @unknown default:
            break
        }
    }

    private func requestAlwaysIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.alwaysRequestKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.alwaysRequestKey)
        manager.requestAlwaysAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            requestAlwaysIfNeeded()
        }
    }
}

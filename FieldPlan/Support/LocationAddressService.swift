import Foundation
import CoreLocation

/// One-shot "where am I standing" → postal address for the Use Current
/// Address button on the project form (CubiCasa-style). Location is
/// requested only on explicit user action; the result goes into the address
/// text field and nothing else is stored or transmitted by the app.
/// (Reverse geocoding itself uses Apple's geocoding service.)
final class LocationAddressService: NSObject, ObservableObject, CLLocationManagerDelegate {

    enum AddressError: LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Location access is off for this app. Allow it in Settings, or type the address manually."
            case .unavailable:
                return "Couldn't determine the address here — please enter it manually."
            }
        }
    }

    @Published var isWorking = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var completion: ((Result<String, Error>) -> Void)?
    private var awaitingAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Requests the current address. The completion runs on the main thread.
    func requestAddress(_ completion: @escaping (Result<String, Error>) -> Void) {
        guard self.completion == nil else { return } // one request at a time
        self.completion = completion
        setWorking(true)
        switch manager.authorizationStatus {
        case .notDetermined:
            awaitingAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(AddressError.denied))
        default:
            manager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingAuthorization else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            awaitingAuthorization = false
            manager.requestLocation()
        case .denied, .restricted:
            awaitingAuthorization = false
            finish(.failure(AddressError.denied))
        default:
            break // still undetermined; keep waiting
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(AddressError.unavailable))
            return
        }
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            if let placemark = placemarks?.first {
                let address = Self.format(placemark)
                if address.isEmpty {
                    self.finish(.failure(AddressError.unavailable))
                } else {
                    self.finish(.success(address))
                }
            } else {
                if let error {
                    AppLog.general.error("Reverse geocoding failed: \(error.localizedDescription)")
                }
                self.finish(.failure(AddressError.unavailable))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.general.error("Location fix failed: \(error.localizedDescription)")
        finish(.failure(AddressError.unavailable))
    }

    // MARK: - Helpers

    /// "123 Main St, Brooklyn, NY 11201"
    static func format(_ placemark: CLPlacemark) -> String {
        var street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        if street.isEmpty {
            street = placemark.name ?? ""
        }
        let statePostal = [placemark.administrativeArea, placemark.postalCode]
            .compactMap { $0 }
            .joined(separator: " ")
        let parts = [street, placemark.locality ?? "", statePostal]
            .filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    private func setWorking(_ working: Bool) {
        DispatchQueue.main.async {
            self.isWorking = working
        }
    }

    private func finish(_ result: Result<String, Error>) {
        DispatchQueue.main.async {
            self.isWorking = false
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }
}

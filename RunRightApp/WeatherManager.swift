import Foundation
import CoreLocation

/// Fetches current weather using the device's location + Open-Meteo (free, no API key).
@MainActor
final class WeatherManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherManager()

    @Published var temperatureF: Int? = nil
    @Published var windMph: Int? = nil
    @Published var conditionIcon: String = "cloud.fill"   // SF Symbol name
    @Published var conditionLabel: String = "Weather"
    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let locationManager = CLLocationManager()
    private var hasLocation = false
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Public

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let location = try await fetchLocation()
            let weather = try await fetchOpenMeteo(lat: location.coordinate.latitude,
                                                   lon: location.coordinate.longitude)
            temperatureF = weather.tempF
            windMph      = weather.windMph
            conditionIcon  = weatherIcon(code: weather.weatherCode)
            conditionLabel = weatherLabel(code: weather.weatherCode)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Location (one-shot)

    private func fetchLocation() async throws -> CLLocation {
        // If we already have a recent location from the system, use it
        if let loc = locationManager.location, abs(loc.timestamp.timeIntervalSinceNow) < 300 {
            return loc
        }

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw WeatherError.locationDenied
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.locationManager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            Task { @MainActor in
                self.continuation?.resume(returning: loc)
                self.continuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // No-op: next call to fetchLocation() re-checks status
    }

    // MARK: - Open-Meteo

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let windSpeed10m: Double
            let weatherCode: Int

            enum CodingKeys: String, CodingKey {
                case temperature2m   = "temperature_2m"
                case windSpeed10m    = "wind_speed_10m"
                case weatherCode     = "weather_code"
            }
        }
        let current: Current
    }

    private struct WeatherResult {
        let tempF: Int
        let windMph: Int
        let weatherCode: Int
    }

    private func fetchOpenMeteo(lat: Double, lon: Double) async throws -> WeatherResult {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",           value: String(format: "%.4f", lat)),
            .init(name: "longitude",          value: String(format: "%.4f", lon)),
            .init(name: "current",            value: "temperature_2m,wind_speed_10m,weather_code"),
            .init(name: "temperature_unit",   value: "fahrenheit"),
            .init(name: "wind_speed_unit",    value: "mph"),
            .init(name: "forecast_days",      value: "1")
        ]
        guard let url = comps.url else { throw WeatherError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WeatherError.httpError
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return WeatherResult(
            tempF: Int(decoded.current.temperature2m.rounded()),
            windMph: Int(decoded.current.windSpeed10m.rounded()),
            weatherCode: decoded.current.weatherCode
        )
    }

    // MARK: - WMO Weather Code → SF Symbol / label

    private func weatherIcon(code: Int) -> String {
        switch code {
        case 0:        return "sun.max.fill"
        case 1, 2:     return "cloud.sun.fill"
        case 3:        return "cloud.fill"
        case 45, 48:   return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86:   return "cloud.snow.fill"
        case 95:       return "cloud.bolt.fill"
        case 96, 99:   return "cloud.bolt.rain.fill"
        default:       return "cloud.fill"
        }
    }

    private func weatherLabel(code: Int) -> String {
        switch code {
        case 0:        return "Clear"
        case 1, 2:     return "Partly Cloudy"
        case 3:        return "Overcast"
        case 45, 48:   return "Foggy"
        case 51...55:  return "Drizzle"
        case 61...65:  return "Rainy"
        case 71...77:  return "Snowy"
        case 80...82:  return "Showers"
        case 85, 86:   return "Snow Showers"
        case 95...99:  return "Thunderstorm"
        default:       return "Cloudy"
        }
    }
}

enum WeatherError: LocalizedError {
    case locationDenied
    case badURL
    case httpError

    var errorDescription: String? {
        switch self {
        case .locationDenied: return "Location access denied — enable in Settings to see weather."
        case .badURL:         return "Invalid weather URL."
        case .httpError:      return "Weather service unavailable."
        }
    }
}

//
//  Weather.swift
//  Wanda
//

import CoreLocation
import Foundation

/// Weather answers without the AI. Forecasts come from Open-Meteo (free, no account or
/// key); only coordinates are sent, never anything about the user. macOS's Weather app
/// doesn't share its data with other apps, so it can't be used directly.
///
/// "Here" is the Mac's location (Location Services), or the city of the Mac's time zone
/// if location access is off.
@MainActor
final class WeatherService: NSObject {
    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    enum Failure: Error {
        case placeNotFound(String)
        case offline
    }

    private let session: URLSession
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var cachedHere: (place: Place, time: Date)?

    init(session: URLSession = .shared) {
        self.session = session
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func answer(_ query: WeatherQuery) async throws -> String {
        let place: Place
        if let name = query.place {
            place = try await search(name)
        } else {
            place = await here()
        }
        let forecast = try await forecast(for: place)
        return WeatherFormatter.answer(query, place: place.name, isHere: query.place == nil, forecast: forecast)
    }

    // MARK: Places

    /// Finds a place by name. "Springfield Illinois" searches "Springfield" and prefers a
    /// result in Illinois.
    private func search(_ name: String) async throws -> Place {
        if let place = try await geocode(name, qualifier: nil) { return place }
        var words = name.split(separator: " ").map(String.init)
        var qualifier: [String] = []
        while words.count > 1 {
            qualifier.insert(words.removeLast(), at: 0)
            if let place = try await geocode(words.joined(separator: " "), qualifier: qualifier.joined(separator: " ")) {
                return place
            }
        }
        throw Failure.placeNotFound(name)
    }

    private func geocode(_ name: String, qualifier: String?) async throws -> Place? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: qualifier == nil ? "1" : "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let response: GeocodingResponse = try await fetch(components.url!)
        let results = response.results ?? []
        let match: GeocodingResponse.Result?
        if let qualifier {
            match = results.first { result in
                [result.admin1, result.country, result.countryCode].compactMap { $0?.lowercased() }
                    .contains { $0 == qualifier || $0.hasPrefix(qualifier) }
            }
        } else {
            match = results.first
        }
        guard let match else { return nil }
        let region = match.countryCode == "US" ? match.admin1 : match.country
        return Place(
            name: [match.name, region].compactMap { $0 }.joined(separator: ", "),
            latitude: match.latitude,
            longitude: match.longitude
        )
    }

    /// Where the Mac is, remembered for 30 minutes.
    private func here() async -> Place {
        if let cachedHere, Date().timeIntervalSince(cachedHere.time) < 30 * 60 {
            return cachedHere.place
        }
        if let location = await currentLocation() {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let place = Place(
                name: placemark?.locality ?? placemark?.name ?? "your area",
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            cachedHere = (place, Date())
            return place
        }
        // No location access: use the time zone's city ("America/Chicago" -> Chicago).
        let city = TimeZone.current.identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? "New York"
        return (try? await search(city)) ?? Place(name: "New York", latitude: 40.71, longitude: -74.01)
    }

    private func currentLocation() async -> CLLocation? {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
        guard locationContinuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
            // Don't wait forever (e.g. the permission prompt is ignored).
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.finishLocation(nil)
            }
        }
    }

    fileprivate func finishLocation(_ location: CLLocation?) {
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    fileprivate func authorizationChanged() {
        switch locationManager.authorizationStatus {
        case .denied, .restricted: finishLocation(nil)
        case .notDetermined: break
        default: if locationContinuation != nil { locationManager.requestLocation() }
        }
    }

    // MARK: Forecast

    private func forecast(for place: Place) async throws -> Forecast {
        let usesUSUnits = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,snowfall_sum"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "temperature_unit", value: usesUSUnits ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: usesUSUnits ? "mph" : "kmh"),
        ]
        var forecast: Forecast = try await fetch(components.url!)
        forecast.windUnit = usesUSUnits ? "mph" : "km/h"
        return forecast
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.offline }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.offline
        }
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finishLocation(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }
}

// MARK: - Open-Meteo responses

private struct GeocodingResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let countryCode: String?
        let admin1: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, country, admin1
            case countryCode = "country_code"
        }
    }

    let results: [Result]?
}

struct Forecast: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let feelsLike: Double
        let code: Int
        let windSpeed: Double
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case feelsLike = "apparent_temperature"
            case code = "weather_code"
            case windSpeed = "wind_speed_10m"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let dates: [String]
        let codes: [Int]
        let highs: [Double]
        let lows: [Double]
        let rainChances: [Int?]
        let snowfall: [Double?]

        enum CodingKeys: String, CodingKey {
            case dates = "time"
            case codes = "weather_code"
            case highs = "temperature_2m_max"
            case lows = "temperature_2m_min"
            case rainChances = "precipitation_probability_max"
            case snowfall = "snowfall_sum"
        }
    }

    let current: Current
    let daily: Daily
    var windUnit = "mph"

    enum CodingKeys: String, CodingKey {
        case current, daily
    }
}

// MARK: - Answers

/// Turns a forecast into a short answer that reads well aloud.
enum WeatherFormatter {
    static func answer(_ query: WeatherQuery, place: String, isHere: Bool, forecast: Forecast) -> String {
        let daily = forecast.daily
        let dayIndex = query.day == .tomorrow ? 1 : 0
        guard daily.dates.indices.contains(dayIndex) else { return "I couldn't get the forecast for \(place)." }
        let inPlace = "in \(place)"

        switch query.focus {
        case .rain:
            if query.day == .week { return weekPrecipitation(daily, place: place, snow: false) }
            let chance = daily.rainChances[dayIndex] ?? 0
            let when = query.day == .tomorrow ? "tomorrow" : "today"
            return "\(verdict(chance)) There's a \(chance)% chance of rain \(when) \(inPlace)."
        case .snow:
            if query.day == .week { return weekPrecipitation(daily, place: place, snow: true) }
            let snow = daily.snowfall[dayIndex] ?? 0
            let snowy = snowCodes.contains(daily.codes[dayIndex]) || snow > 0
            let when = query.day == .tomorrow ? "tomorrow" : "today"
            return snowy
                ? "Yes, snow is expected \(when) \(inPlace)."
                : "No snow is expected \(when) \(inPlace)."
        case .general, .temperature:
            break
        }

        switch query.day {
        case .now:
            let current = forecast.current
            var text = "Right now \(inPlace) it's \(degrees(current.temperature)) and \(describe(current.code, isDay: current.isDay == 1))"
            if abs(current.feelsLike - current.temperature) >= 3 {
                text += ", feeling like \(degrees(current.feelsLike))"
            }
            text += ". " + dayLine("Today", daily, 0, withRain: query.focus == .general)
            return text
        case .today:
            return dayLine("Today \(inPlace)", daily, 0, withRain: true)
                + " It's \(degrees(forecast.current.temperature)) right now."
        case .tomorrow:
            return dayLine("Tomorrow \(inPlace)", daily, 1, withRain: true)
        case .week:
            let lines = daily.dates.indices.map { index in
                "\(dayName(daily.dates[index], index: index)): \(describe(daily.codes[index])), "
                    + "high \(degrees(daily.highs[index])), low \(degrees(daily.lows[index]))"
                    + rainNote(daily.rainChances[index])
            }
            return (["This week \(inPlace):"] + lines).joined(separator: "\n")
        }
    }

    private static func dayLine(_ label: String, _ daily: Forecast.Daily, _ index: Int, withRain: Bool) -> String {
        "\(label): \(describe(daily.codes[index])), high of \(degrees(daily.highs[index])), low of \(degrees(daily.lows[index]))"
            + (withRain ? rainNote(daily.rainChances[index]) : "") + "."
    }

    private static func rainNote(_ chance: Int?) -> String {
        guard let chance, chance >= 20 else { return "" }
        return ", \(chance)% chance of rain"
    }

    private static func verdict(_ chance: Int) -> String {
        switch chance {
        case 60...: return "Yes, probably."
        case 30..<60: return "Maybe."
        default: return "Probably not."
        }
    }

    private static func weekPrecipitation(_ daily: Forecast.Daily, place: String, snow: Bool) -> String {
        let days = daily.dates.indices.filter { index in
            snow
                ? snowCodes.contains(daily.codes[index]) || (daily.snowfall[index] ?? 0) > 0
                : (daily.rainChances[index] ?? 0) >= 50
        }
        let kind = snow ? "snow" : "rain"
        guard !days.isEmpty else { return "No \(kind) is expected in \(place) this week." }
        let names = days.map { index in
            index < 2 ? dayName(daily.dates[index], index: index).lowercased() : "on " + dayName(daily.dates[index], index: index)
        }
        return "\(kind.capitalized) is likely in \(place) \(ListFormatter.localizedString(byJoining: names))."
    }

    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    private static func dayName(_ date: String, index: Int) -> String {
        if index == 0 { return "Today" }
        if index == 1 { return "Tomorrow" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.wide))
    }

    private static let snowCodes: Set<Int> = [71, 73, 75, 77, 85, 86]

    /// WMO weather codes, as used by Open-Meteo.
    static func describe(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sunny" : "clear"
        case 1: return isDay ? "mostly sunny" : "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzly"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rainy"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snowy"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "heavy rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed conditions"
        }
    }
}

import Foundation

public enum Precipitation: String, CaseIterable, Codable, Sendable {
    case none, snow, rain
}

/// What should be falling, in the app's own terms.
public struct WeatherState: Equatable, Sendable {
    public var precipitation: Precipitation
    /// 0...1
    public var intensity: Float
    /// 0...1
    public var fog: Float
    /// -1...1, positive blows toward screen-right (east).
    public var wind: Float
    public var summary: String

    public init(precipitation: Precipitation, intensity: Float, fog: Float, wind: Float, summary: String) {
        self.precipitation = precipitation
        self.intensity = intensity
        self.fog = fog
        self.wind = wind
        self.summary = summary
    }

    /// Maps Open-Meteo "current" fields to an effect.
    /// WMO weather codes: https://open-meteo.com/en/docs (weather_code table).
    /// `windDirection` is where the wind comes FROM, in degrees (meteorological).
    public static func fromOpenMeteo(code: Int, windKmh: Double, windDirection: Double) -> WeatherState {
        var p = Precipitation.none
        var i: Float = 0
        var fog: Float = 0
        let summary: String
        switch code {
        case 0: summary = "Clear"
        case 1: summary = "Mostly clear"
        case 2: summary = "Partly cloudy"
        case 3: summary = "Overcast"
        case 45, 48: summary = "Fog"; fog = 0.75
        case 51: summary = "Light drizzle"; p = .rain; i = 0.2
        case 53: summary = "Drizzle"; p = .rain; i = 0.32
        case 55: summary = "Heavy drizzle"; p = .rain; i = 0.45
        case 56, 57: summary = "Freezing drizzle"; p = .rain; i = 0.35
        case 61: summary = "Light rain"; p = .rain; i = 0.38
        case 63: summary = "Rain"; p = .rain; i = 0.6
        case 65: summary = "Heavy rain"; p = .rain; i = 0.9
        case 66, 67: summary = "Freezing rain"; p = .rain; i = 0.6
        case 71: summary = "Light snow"; p = .snow; i = 0.35
        case 73: summary = "Snow"; p = .snow; i = 0.6
        case 75: summary = "Heavy snow"; p = .snow; i = 0.9
        case 77: summary = "Snow grains"; p = .snow; i = 0.3
        case 80: summary = "Light showers"; p = .rain; i = 0.4
        case 81: summary = "Showers"; p = .rain; i = 0.65
        case 82: summary = "Violent showers"; p = .rain; i = 0.95
        case 85: summary = "Snow showers"; p = .snow; i = 0.5
        case 86: summary = "Heavy snow showers"; p = .snow; i = 0.85
        case 95: summary = "Thunderstorm"; p = .rain; i = 0.85
        case 96, 99: summary = "Thunderstorm, hail"; p = .rain; i = 0.95
        default: summary = "Unknown"
        }
        if p == .rain, i > 0.5 { fog = max(fog, 0.25) }
        // Wind from 270° (west) blows toward the east → screen-right.
        let toward = -sin(windDirection * .pi / 180)
        let strength = min(windKmh / 45.0, 1.0)
        let wind = Float(toward * strength)
        return WeatherState(precipitation: p, intensity: i, fog: fog, wind: wind, summary: summary)
    }
}

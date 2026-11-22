import Foundation
import Combine
import SnowsillCore

/// Live weather from Open-Meteo (free, no API key). Only the city name the
/// user typed and its coordinates are sent; no location permission.
final class WeatherService: ObservableObject {
    @Published private(set) var current: WeatherState?
    @Published private(set) var place: String = ""
    @Published private(set) var status: String = "Type a city to match its weather. Until then, your manual settings are used."
    @Published private(set) var updated: Date?

    private var lat: Double?
    private var lon: Double?
    private var timer: Timer?
    private var task: Task<Void, Never>?

    func setCity(_ name: String) {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        status = "Looking up \(q)…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                c.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "1"), .init(name: "format", value: "json")]
                let (data, _) = try await URLSession.shared.data(from: c.url!)
                struct Geo: Decodable { struct R: Decodable { let name: String; let latitude: Double; let longitude: Double; let country: String? }; let results: [R]? }
                let g = try JSONDecoder().decode(Geo.self, from: data)
                guard let r = g.results?.first else {
                    await MainActor.run { self.status = "Couldn't find “\(q)”." }
                    return
                }
                await MainActor.run {
                    self.lat = r.latitude; self.lon = r.longitude
                    self.place = [r.name, r.country].compactMap { $0 }.joined(separator: ", ")
                }
                await self.refresh()
            } catch {
                if !Task.isCancelled { await MainActor.run { self.status = "Offline: couldn't reach the weather service." } }
            }
        }
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard let lat, let lon else { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [.init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
                        .init(name: "current", value: "weather_code,wind_speed_10m,wind_direction_10m")]
        do {
            let (data, _) = try await URLSession.shared.data(from: c.url!)
            struct F: Decodable { struct C: Decodable { let weather_code: Int; let wind_speed_10m: Double; let wind_direction_10m: Double }; let current: C }
            let f = try JSONDecoder().decode(F.self, from: data)
            let s = WeatherState.fromOpenMeteo(code: f.current.weather_code, windKmh: f.current.wind_speed_10m,
                                               windDirection: f.current.wind_direction_10m)
            await MainActor.run {
                self.current = s
                self.updated = Date()
                self.status = "\(self.place): \(s.summary), wind \(Int(f.current.wind_speed_10m.rounded())) km/h"
            }
        } catch {
            await MainActor.run { self.status = "Offline: showing the last known weather." }
        }
    }
}

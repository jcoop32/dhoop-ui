//
//  NetworkManager.swift
//  dhoop-ui
//

import Foundation

// MARK: - UserDefaults Keys
enum DhoopDefaults {
    static let targetIP  = "dhoop_targetIP"
    static let targetPort = "dhoop_targetPort"
    static let apiKey    = "dhoop_apiKey"

    // Default values — also mirrored in SettingsView @AppStorage declarations
    static let defaultIP   = "100.127.237.13"
    static let defaultPort = "9001"
    static let defaultKey  = "dhoop-admin"
}

// MARK: - API Response Models
struct LatestResponse: Decodable { let hr: [HRRecord] }
struct HRRecord: Decodable { let heart_rate: Int }

struct Baselines: Decodable {
    let status: String?
    let hrv_low: Double
    let hrv_high: Double
    let rhr_low: Double
    let rhr_high: Double

    var hasData: Bool { (hrv_high - hrv_low) > 0.01 }
}

struct DailyRecord: Decodable, Identifiable {
    let date: String
    let sleep_score: Int
    let strain: Double
    let resting_hr: Double?
    let hrv_rmssd: Double?
    let sleep_duration_min: Double?
    let time_in_bed_min: Double?
    let disturbances: Int?
    var id: String { date }

    var formattedDate: String {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d"
        return iso.date(from: date).map { display.string(from: $0) } ?? date
    }
    
    var isToday: Bool {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone.current
        let todayStr = iso.string(from: Date())
        return date == todayStr
    }
}

// MARK: - NetworkManager
final class NetworkManager {

    // Dedicated serial background queue — CoreBluetooth callbacks never touch Main.
    private let session: URLSession = {
        let queue = OperationQueue()
        queue.name = "com.dhoop.network"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: .ephemeral,
                          delegate: nil,
                          delegateQueue: queue)
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Public API

    /// Fire-and-forget POST to /ingest.
    /// Reads target IP, port, and API key from UserDefaults at call-time so that
    /// Settings changes take effect on the very next BLE packet — no restart needed.
    func ingest(hexPayload: String) {
        let defaults = UserDefaults.standard
        let ip   = defaults.string(forKey: DhoopDefaults.targetIP)   ?? DhoopDefaults.defaultIP
        let port = defaults.string(forKey: DhoopDefaults.targetPort) ?? DhoopDefaults.defaultPort
        let key  = defaults.string(forKey: DhoopDefaults.apiKey)     ?? DhoopDefaults.defaultKey

        guard let url = URL(string: "http://\(ip):\(port)/ingest") else {
            print("[NetworkManager] Invalid URL — ip=\(ip) port=\(port)")
            return
        }

        // Build JSON body
        let body: [String: String] = [
            "timestamp":   isoFormatter.string(from: Date()),
            "hex_payload": hexPayload
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        // Build request
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key,                forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3  // fail fast; don't queue-back-pressure on rapid BLE updates

        // Fire and forget — completion is intentionally lightweight
        session.dataTask(with: request) { _, response, error in
            if let error = error {
                // Only log transport errors — do NOT surface to UI to avoid flooding
                print("[NetworkManager] POST failed: \(error.localizedDescription)")
            }
        }.resume()
    }

    /// Fire-and-forget POST to /ping to indicate the BLE connection is active.
    func sendPing() {
        let defaults = UserDefaults.standard
        let ip   = defaults.string(forKey: DhoopDefaults.targetIP)   ?? DhoopDefaults.defaultIP
        let port = defaults.string(forKey: DhoopDefaults.targetPort) ?? DhoopDefaults.defaultPort
        let key  = defaults.string(forKey: DhoopDefaults.apiKey)     ?? DhoopDefaults.defaultKey

        guard let url = URL(string: "http://\(ip):\(port)/ping") else { return }

        let body: [String: String] = ["status": "connected"]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key,                forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3

        // Fire and forget
        session.dataTask(with: request).resume()
    }

    /// Fire-and-forget POST to /ingest/battery with the current Whoop battery percentage.
    func sendBattery(level: Int) {
        let defaults = UserDefaults.standard
        let ip   = defaults.string(forKey: DhoopDefaults.targetIP)   ?? DhoopDefaults.defaultIP
        let port = defaults.string(forKey: DhoopDefaults.targetPort) ?? DhoopDefaults.defaultPort
        let key  = defaults.string(forKey: DhoopDefaults.apiKey)     ?? DhoopDefaults.defaultKey

        guard let url = URL(string: "http://\(ip):\(port)/ingest/battery") else { return }

        let body: [String: Int] = ["battery_level": level]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key,                forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3

        // Fire and forget
        session.dataTask(with: request).resume()
    }

    /// GET /api/latest — returns the most recent backend-verified HR.
    func fetchLatestHR() async -> Int? {
        let defaults = UserDefaults.standard
        let ip   = defaults.string(forKey: DhoopDefaults.targetIP)   ?? DhoopDefaults.defaultIP
        let port = defaults.string(forKey: DhoopDefaults.targetPort) ?? DhoopDefaults.defaultPort
        let key  = defaults.string(forKey: DhoopDefaults.apiKey)     ?? DhoopDefaults.defaultKey

        guard let url = URL(string: "http://\(ip):\(port)/api/latest") else { return nil }

        var request        = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 3

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response  = try? JSONDecoder().decode(LatestResponse.self, from: data)
        else { return nil }

        return response.hr.first?.heart_rate
    }

    /// Triggers the backend algorithms to calculate strain and sleep for the current day
    func calculateTodayMetrics() async {
        guard let strainURL = makeURL("/api/strain"), let sleepURL = makeURL("/api/sleep") else { return }
        _ = try? await URLSession.shared.data(for: makeGETRequest(strainURL))
        _ = try? await URLSession.shared.data(for: makeGETRequest(sleepURL))
    }

    // MARK: - History API

    func fetchBaselines() async -> Baselines? {
        guard let url = makeURL("/api/baselines") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: makeGETRequest(url)) else { return nil }
        return try? JSONDecoder().decode(Baselines.self, from: data)
    }

    func fetchHistory() async -> [DailyRecord] {
        guard let url = makeURL("/api/history") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(for: makeGETRequest(url)) else { return [] }
        return (try? JSONDecoder().decode([DailyRecord].self, from: data)) ?? []
    }

    // MARK: - Private Helpers

    private func makeURL(_ path: String) -> URL? {
        let ip   = UserDefaults.standard.string(forKey: DhoopDefaults.targetIP)   ?? DhoopDefaults.defaultIP
        let port = UserDefaults.standard.string(forKey: DhoopDefaults.targetPort) ?? DhoopDefaults.defaultPort
        return URL(string: "http://\(ip):\(port)\(path)")
    }

    private func makeGETRequest(_ url: URL) -> URLRequest {
        let key = UserDefaults.standard.string(forKey: DhoopDefaults.apiKey) ?? DhoopDefaults.defaultKey
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 5
        return req
    }
}

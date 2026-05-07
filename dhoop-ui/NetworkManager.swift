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
}

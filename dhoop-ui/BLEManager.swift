//
//  BLEManager.swift
//  dhoop-ui
//

import Foundation
import CoreBluetooth
import Combine

// Known Whoop characteristic UUIDs
private let kCmdToStrap   = CBUUID(string: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6") // CMD_TO_STRAP     (write trigger)
private let kWhoopEvents  = CBUUID(string: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6") // EVENTS_FROM_STRAP (low-freq)
private let kWhoopData    = CBUUID(string: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6") // DATA_FROM_STRAP  (accel + PPG firehose)
private let kHeartRate    = CBUUID(string: "2A37")
private let kBattery      = CBUUID(string: "2A19")
private let kManufacturer = CBUUID(string: "2A29")

final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published state
    @Published var connectionStatus : String       = "Idle"
    @Published var logEntries       : [LogEntry]   = []
    @Published var isScanning       : Bool         = false

    // Live sensor values
    @Published var heartRate        : Int?         = nil
    @Published var batteryLevel     : Int?         = nil
    @Published var manufacturerName : String?      = nil
    @Published var sensorPackets    : [SensorPacket] = []

    // MARK: - CoreBluetooth
    private var centralManager  : CBCentralManager!
    private var whoopPeripheral : CBPeripheral?
    private var pingTimer       : Timer?

    // MARK: - Networking
    private let network = NetworkManager()

    // MARK: - Init
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API
    func startScan() {
        guard centralManager.state == .poweredOn else {
            appendLog(.system, "Central not powered on yet.")
            return
        }
        logEntries.removeAll()
        sensorPackets.removeAll()
        heartRate    = nil
        batteryLevel = nil
        connectionStatus = "Scanning…"
        isScanning       = true
        appendLog(.system, "Scanning for Whoop…")
        // Filter directly to Whoop's root service — suppresses all other BLE devices
        let whoopRootSvc = CBUUID(string: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6")
        centralManager.scanForPeripherals(withServices: [whoopRootSvc], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning       = false
        connectionStatus = "Idle"
        appendLog(.system, "Scan stopped — \(logEntries.count) entries captured")
    }

    func exportText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return logEntries.map { e in
            "[\(fmt.string(from: e.timestamp))] [\(e.source.rawValue)] \(e.detail)"
        }.joined(separator: "\n")
    }

    func disconnect() {
        guard let p = whoopPeripheral else { return }
        centralManager.cancelPeripheralConnection(p)
    }

    // MARK: - Helpers
    private func appendLog(_ source: LogSource, _ detail: String) {
        let entry = LogEntry(source: source, detail: detail)
        logEntries.append(entry)
        print("[\(source.rawValue)] \(detail)")
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog(.system, "Bluetooth powered ON — ready to scan")
        case .poweredOff:
            connectionStatus = "Bluetooth Off"
            appendLog(.system, "Bluetooth powered off")
        case .unauthorized:
            connectionStatus = "Not Authorized"
            appendLog(.system, "Bluetooth not authorized")
        case .unsupported:
            connectionStatus = "Unsupported"
        case .resetting:
            appendLog(.system, "Bluetooth resetting")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        // Only Whoop devices reach here (scan is already filtered by service UUID)
        let name = peripheral.name ?? "Whoop"
        appendLog(.system, "✅ Found \(name)  RSSI: \(RSSI) dBm — connecting…")
        central.stopScan()
        isScanning          = false
        connectionStatus    = "Connecting…"
        whoopPeripheral     = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = "Connected ✓"
        appendLog(.system, "Connected to \(peripheral.name ?? "Whoop")")
        peripheral.discoverServices(nil)
        
        // Start ping timer to indicate active connection
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.network.sendPing()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Connection Failed"
        appendLog(.system, "Failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Disconnected"
        whoopPeripheral  = nil
        heartRate        = nil
        
        // Stop pinging backend
        pingTimer?.invalidate()
        pingTimer = nil
        
        appendLog(.system, "Disconnected: \(error?.localizedDescription ?? "clean")")
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        appendLog(.system, "Discovered \(services.count) service(s) — enumerating characteristics…")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: char)
            }
            // Read one-shot values immediately
            if char.uuid == kManufacturer || char.uuid == kBattery {
                peripheral.readValue(for: char)
            }
            // Send "Start Activity" trigger to unlock the high-frequency sensor stream
            if char.uuid == kCmdToStrap {
                let hex = "aa0800a8238c03017d5ec627"
                let triggerData = Data(stride(from: 0, to: hex.count, by: 2).compactMap {
                    UInt8(hex[hex.index(hex.startIndex, offsetBy: $0) ...
                             hex.index(hex.startIndex, offsetBy: $0 + 1)], radix: 16)
                })
                peripheral.writeValue(triggerData, for: char, type: .withoutResponse)
                appendLog(.system, "Sent trigger command to CMD_TO_STRAP")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        switch characteristic.uuid {
        case kHeartRate:
            if let bpm = parseHeartRate(data) {
                heartRate = bpm
                appendLog(.data, "❤️ Heart Rate: \(bpm) BPM")
            }

        case kBattery:
            let level = Int(data[0])
            batteryLevel = level
            appendLog(.data, "🔋 Battery: \(level)%")

        case kManufacturer:
            if let name = String(data: data, encoding: .utf8) {
                manufacturerName = name
                appendLog(.system, "Manufacturer: \(name)")
            }

        case kWhoopEvents:
            // EVENTS_FROM_STRAP — low-frequency; log to UI only, do not forward
            let evtHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog(.data, "\(characteristic.uuid.uuidString)  →  \(evtHex)")

        case kWhoopData:
            // DATA_FROM_STRAP — high-frequency accel + PPG firehose; log + forward to ingest
            if let packet = SensorPacket(data: data) {
                if sensorPackets.count >= 300 { sensorPackets.removeFirst() }
                sensorPackets.append(packet)
            }
            let dataHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog(.data, "\(characteristic.uuid.uuidString)  →  \(dataHex)")
            network.ingest(hexPayload: dataHex)

        default:
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog(.data, "\(characteristic.uuid.uuidString)  →  \(hex)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog(.system, "Notify error for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        }
    }

    // MARK: Parsers
    private func parseHeartRate(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let flags = data[0]
        if flags & 0x01 == 0 {
            return Int(data[1])
        } else if data.count >= 3 {
            return Int(data[1]) | (Int(data[2]) << 8)
        }
        return nil
    }


}

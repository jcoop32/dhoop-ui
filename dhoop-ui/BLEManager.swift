//
//  BLEManager.swift
//  dhoop-ui
//

import Foundation
import CoreBluetooth
import Combine
import UIKit

// Known Whoop characteristic UUIDs
private let kCmdToStrap   = CBUUID(string: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6") // CMD_TO_STRAP     (write trigger)
private let kWhoopEvents  = CBUUID(string: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6") // EVENTS_FROM_STRAP (low-freq)
private let kWhoopData    = CBUUID(string: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6") // DATA_FROM_STRAP  (accel + PPG firehose)
private let kHeartRate    = CBUUID(string: "2A37")
private let kBattery      = CBUUID(string: "2A19")
private let kManufacturer = CBUUID(string: "2A29")

// MARK: - FrameReassembler
/// Buffers raw BLE fragments from DATA_FROM_STRAP and reconstructs complete Gen4 frames.
///
/// Gen4 frame layout:
///   [0]    0xAA  — magic sync byte
///   [1..2] UInt16 LE — total body length (everything after the 4-byte header)
///   [3]    CRC-8 of bytes [1..2]
///   [4 ..  3+length] body
///
/// A frame is "complete" once buffer.count >= length + 4.
final class FrameReassembler {

    private var buffer: [UInt8] = []

    /// Called when a complete frame has been extracted.
    var onFrame: ((_ hexPayload: String) -> Void)?

    /// Feed new bytes from a BLE notification chunk.
    func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        consumeFrames()
    }

    private func consumeFrames() {
        // Keep consuming until we can no longer extract a complete frame.
        while true {
            // Scan forward to find the 0xAA sync byte.
            guard let syncIdx = buffer.firstIndex(of: 0xAA) else {
                buffer.removeAll()
                return
            }
            if syncIdx > 0 {
                // Drop any leading garbage bytes before the sync marker.
                buffer.removeFirst(syncIdx)
            }

            // Need at least 4 bytes for the header (magic + 2-byte length + crc8).
            guard buffer.count >= 4 else { return }

            // Read body length as Little-Endian UInt16.
            let bodyLength = Int(buffer[1]) | (Int(buffer[2]) << 8)
            let totalFrame = 4 + bodyLength   // header(4) + body

            guard buffer.count >= totalFrame else { return }  // wait for more data

            // Extract the complete frame.
            let frame = Array(buffer.prefix(totalFrame))
            buffer.removeFirst(totalFrame)

            // Convert to hex string and fire callback.
            let hex = frame.map { String(format: "%02X", $0) }.joined()
            onFrame?(hex)
        }
    }

    /// Reset internal buffer (e.g., on disconnect).
    func reset() { buffer.removeAll() }
}

// MARK: - CRC Engines (ported from whoopsie Dart)

/// CRC-8 (Maxim/Dallas, poly 0x31, init 0x00, no reflection).
/// Used to checksum the 2-byte length field in the Gen4 packet header.
private let crc8Table: [UInt8] = {
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt8(i)
        for _ in 0..<8 {
            crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x31 : crc << 1
        }
        table[i] = crc
    }
    return table
}()

private func crc8(_ bytes: [UInt8]) -> UInt8 {
    var crc: UInt8 = 0x00
    for byte in bytes {
        crc = crc8Table[Int(crc ^ byte)]
    }
    return crc
}

/// CRC-32 (IEEE 802.3, poly 0xEDB88320 reflected, init 0xFFFFFFFF).
/// Used as the 4-byte trailing checksum of the full Gen4 packet.
private let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt32(i)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        table[i] = crc
    }
    return table
}()

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in bytes {
        let idx = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = (crc >> 8) ^ crc32Table[idx]
    }
    return crc ^ 0xFFFFFFFF
}

// MARK: - BLEManager

final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published state
    @Published var connectionStatus : String       = "Idle"
    @Published var logEntries       : [LogEntry]   = []
    @Published var isScanning       : Bool         = false

    // Live sensor values
    @Published var heartRate        : Int?         = nil
    @Published var backendHR        : Int?         = nil
    @Published var batteryLevel     : Int?         = nil
    @Published var manufacturerName : String?      = nil
    @Published var sensorPackets    : [SensorPacket] = []

    // MARK: - CoreBluetooth
    private var centralManager    : CBCentralManager!
    private var whoopPeripheral   : CBPeripheral?
    private var cmdCharacteristic : CBCharacteristic?
    private var pingTimer         : Timer?

    // MARK: - Frame reassembly
    private let reassembler = FrameReassembler()

    // MARK: - Networking
    private let network = NetworkManager()

    // MARK: - Init
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)

        // Wire up reassembler → ingest pipeline
        reassembler.onFrame = { [weak self] hexPayload in
            guard let self else { return }
            self.network.ingest(hexPayload: hexPayload)
            self.appendLog(.data, "🧩 Frame → \(hexPayload.prefix(32))…")
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        reassembler.reset()
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

    func triggerHistoricalSync() {
        guard let p = whoopPeripheral, let char = cmdCharacteristic else {
            appendLog(.system, "Cannot sync: Not connected or CMD characteristic missing.")
            return
        }
        // cmd: 0x16 is SEND_HISTORICAL_DATA. We use an arbitrary sequence number like 0x99.
        let pkt = buildPacket(seq: 0x99, cmd: 0x16, payload: [0x00])
        p.writeValue(pkt, for: char, type: .withoutResponse)

        let hexStr = pkt.map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog(.system, "📡 Sent historical sync: \(hexStr)")
    }

    // MARK: - Gen4 Packet Builder
    /// Builds a complete Gen4 command packet matching the whoopsie wire format:
    ///   AA [lenLo] [lenHi] [crc8(len)] 23 [seq] [cmd] [payload] [zero-pad to 8 body bytes] [crc32 LE 4 bytes]
    ///
    /// - Parameters:
    ///   - seq: Sequence byte (e.g. 0xA0, increments per command).
    ///   - cmd: Command opcode (e.g. 0x03 = Toggle HR).
    ///   - payload: Command-specific payload bytes.
    /// - Returns: Fully framed `Data` ready for `.writeValue(_:for:type:)`.
    func buildPacket(seq: UInt8, cmd: UInt8, payload: [UInt8]) -> Data {
        var inner = [UInt8]()
        inner.append(0x23)
        inner.append(seq)
        inner.append(cmd)
        inner.append(contentsOf: payload)

        // Pad to a multiple of 4 bytes
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 {
            inner.append(contentsOf: [UInt8](repeating: 0, count: pad))
        }

        let length = UInt16(inner.count + 4) // MUST include +4 for CRC32
        let lenLo = UInt8(length & 0xFF)
        let lenHi = UInt8((length >> 8) & 0xFF)

        let headerCRC = crc8([lenLo, lenHi])
        let checksum = crc32(inner) // Compute ONLY over the inner body!

        var packet: [UInt8] = [0xAA, lenLo, lenHi, headerCRC]
        packet.append(contentsOf: inner)
        packet.append(UInt8(checksum & 0xFF))
        packet.append(UInt8((checksum >> 8)  & 0xFF))
        packet.append(UInt8((checksum >> 16) & 0xFF))
        packet.append(UInt8((checksum >> 24) & 0xFF))

        return Data(packet)
    }

    // MARK: - Helpers
    private func appendLog(_ source: LogSource, _ detail: String) {
        let entry = LogEntry(source: source, detail: detail)
        logEntries.append(entry)
        print("[\(source.rawValue)] \(detail)")
    }

    /// CRC-16/CCITT-FALSE — poly 0x1021, init 0xFFFF, no reflection
    private func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
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
        
        // Start ping timer to indicate active connection + poll backend HR
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.network.sendPing()
            Task { [weak self] in
                let latestHR = await self?.network.fetchLatestHR()
                await MainActor.run { self?.backendHR = latestHR }
            }
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
        whoopPeripheral   = nil
        cmdCharacteristic = nil
        heartRate        = nil
        backendHR        = nil
        reassembler.reset()
        
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
            if char.uuid == kCmdToStrap {
                cmdCharacteristic = char
                appendLog(.system, "CMD_TO_STRAP ready — trigger deferred to scene phase")
                // Live-stream trigger is sent by appDidBecomeActive(), NOT here,
                // so backgrounded reconnects never force the strap into high-power mode.
                sendLiveStreamTrigger()
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
            network.sendBattery(level: level)

        case kManufacturer:
            if let name = String(data: data, encoding: .utf8) {
                manufacturerName = name
                appendLog(.system, "Manufacturer: \(name)")
            }

        case kWhoopEvents:
            // EVENTS_FROM_STRAP — low-frequency event + battery broadcast
            let evtHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog(.data, "\(characteristic.uuid.uuidString)  →  \(evtHex)")

            // Extract real battery level — offset 2, easy to change
            let kBatteryByteOffset = 2
            if data.count > kBatteryByteOffset {
                let rawBattery = Int(data[kBatteryByteOffset])
                // Sanity-check: valid percentage is 0–100
                if (0...100).contains(rawBattery) {
                    batteryLevel = rawBattery
                    network.sendBattery(level: rawBattery)
                }
            }

        case kWhoopData:
            // DATA_FROM_STRAP — high-frequency accel + PPG firehose.
            // BLE MTU (~185 bytes) means large packets (e.g. 1,300-byte R10 IMU)
            // arrive as fragments. Feed each chunk into the FrameReassembler;
            // onFrame fires only when a complete Gen4 frame has been buffered.
            let bytes = [UInt8](data)

            // Also attempt immediate SensorPacket decode for live UI metrics.
            if let packet = SensorPacket(data: data) {
                if sensorPackets.count >= 300 { sensorPackets.removeFirst() }
                sensorPackets.append(packet)
            }

            // Log the raw chunk (abbreviated so logs stay readable).
            let chunkHex = bytes.prefix(16).map { String(format: "%02X", $0) }.joined()
            appendLog(.data, "\(characteristic.uuid.uuidString)  →  \(chunkHex)… (\(bytes.count)B)")

            // Feed into reassembler — ingest fires on complete frame via onFrame closure.
            reassembler.append(bytes)

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

// MARK: - Scene Phase & BLE Command Writers
extension BLEManager {

    @objc private func appDidBecomeActive() {
        sendLiveStreamTrigger()
    }

    @objc private func appDidEnterBackground() {
        sendBackgroundRecordCommand()
    }

    /// Sends the four Gen4 stream-enable commands with the delays required by
    /// the Whoop firmware state machine (ported from whoopsie Dart reference):
    ///
    ///   seq=0xA0  cmd=0x03  payload=[0x01]  → Toggle HR          (wait 50ms)
    ///   seq=0xA1  cmd=0x3F  payload=[0x01]  → Send R10 IMU       (wait 50ms)
    ///   seq=0xA2  cmd=0x9A  payload=[0x01]  → Toggle Optical R21 (wait 100ms)
    ///   seq=0xA3  cmd=0x6C  payload=[0x01]  → SpO2 enable
    private func sendLiveStreamTrigger() {
        guard let p = whoopPeripheral,
              let char = cmdCharacteristic,
              p.state == .connected else { return }

        var seq: UInt8 = 0xA0

        // Helper: write a packet immediately and bump the sequence counter.
        func send(cmd: UInt8, payload: [UInt8]) {
            let pkt = buildPacket(seq: seq, cmd: cmd, payload: payload)
            p.writeValue(pkt, for: char, type: .withoutResponse)
            let hex = pkt.map { String(format: "%02X", $0) }.joined()
            appendLog(.system, "📤 cmd=0x\(String(format: "%02X", cmd)) seq=0x\(String(format: "%02X", seq)) → \(hex)")
            seq &+= 1
        }

        // Packet 1: Toggle HR — fire immediately.
        send(cmd: 0x03, payload: [0x01])

        // Packet 2: Send R10 IMU — 50ms after packet 1.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x3F, payload: [0x01])
        }

        // Packet 3: Toggle Optical R21 (SpO2 sensor) — 100ms after packet 1.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x9A, payload: [0x01])
        }

        // Packet 4: SpO2 enable — 200ms after packet 1.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x6C, payload: [0x01])
            self.appendLog(.system, "🟢 Live-stream sequence complete")
        }
    }

    private func sendBackgroundRecordCommand() {
        guard let p = whoopPeripheral,
              let char = cmdCharacteristic,
              p.state == .connected else { return }
        // Stop Activity — reverts strap to low-power Record-and-Dump mode
        let bytes: [UInt8] = [0xAA, 0x01, 0x00, 0x55]
        p.writeValue(Data(bytes), for: char, type: .withoutResponse)
        appendLog(.system, "🔴 Background: sent stop/record command")
    }
}

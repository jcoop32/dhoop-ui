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
private let kCmdFromStrap = CBUUID(string: "61080003-8D6D-82B8-614A-1C8CB0F8DCC6") // CMD_FROM_STRAP   (response channel)
private let kWhoopEvents  = CBUUID(string: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6") // EVENTS_FROM_STRAP (low-freq)
private let kWhoopData    = CBUUID(string: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6") // DATA_FROM_STRAP  (accel + PPG firehose)
private let kHeartRate    = CBUUID(string: "2A37")
private let kBattery      = CBUUID(string: "2A19")  // Standard battery — returns fake 100%; ignored in favour of 0x24 response
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
    var onFrame: ((_ frame: [UInt8]) -> Void)?

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

            // Validate the header CRC-8 over the two length bytes.
            // If it fails the 0xAA we found is not a real frame start — pop it and
            // keep scanning so we don't trust a garbage length value.
            let expectedHeaderCRC = crc8([buffer[1], buffer[2]])
            guard buffer[3] == expectedHeaderCRC else {
                buffer.removeFirst()   // discard the false sync byte
                continue               // re-scan from the new head
            }

            // Read body length as Little-Endian UInt16.
            let bodyLength = Int(buffer[1]) | (Int(buffer[2]) << 8)
            let totalFrame = 4 + bodyLength   // header(4) + body

            guard buffer.count >= totalFrame else { return }  // wait for more data

            // Extract the complete frame.
            let frame = Array(buffer.prefix(totalFrame))
            buffer.removeFirst(totalFrame)

            // Fire callback with raw bytes — hex encoding happens only in UI layer.
            onFrame?(frame)
        }
    }

    /// Reset internal buffer (e.g., on disconnect).
    func reset() { buffer.removeAll() }
}

// MARK: - CRC Engines (ported from whoopsie Dart)

/// CRC-8 (Maxim/Dallas, poly 0x31, init 0x00, no reflection).
/// Used to checksum the 2-byte length field in the Gen4 packet header.
private let crc8Table: [UInt8] = [
      0,   7,  14,   9,  28,  27,  18,  21,  56,  63,  54,  49,  36,  35,  42,  45,
    112, 119, 126, 121, 108, 107,  98, 101,  72,  79,  70,  65,  84,  83,  90,  93,
    224, 231, 238, 233, 252, 251, 242, 245, 216, 223, 214, 209, 196, 195, 202, 205,
    144, 151, 158, 153, 140, 139, 130, 133, 168, 175, 166, 161, 180, 179, 186, 189,
    199, 192, 201, 206, 219, 220, 213, 210, 255, 248, 241, 246, 227, 228, 237, 234,
    183, 176, 185, 190, 171, 172, 165, 162, 143, 136, 129, 134, 147, 148, 157, 154,
     39,  32,  41,  46,  59,  60,  53,  50,  31,  24,  17,  22,   3,   4,  13,  10,
     87,  80,  89,  94,  75,  76,  69,  66, 111, 104,  97, 102, 115, 116, 125, 122,
    137, 142, 135, 128, 149, 146, 155, 156, 177, 182, 191, 184, 173, 170, 163, 164,
    249, 254, 247, 240, 229, 226, 235, 236, 193, 198, 207, 200, 221, 218, 211, 212,
    105, 110, 103,  96, 117, 114, 123, 124,  81,  86,  95,  88,  77,  74,  67,  68,
     25,  30,  23,  16,   5,   2,  11,  12,  33,  38,  47,  40,  61,  58,  51,  52,
     78,  73,  64,  71,  82,  85,  92,  91, 118, 113, 120, 127, 106, 109, 100,  99,
     62,  57,  48,  55,  34,  37,  44,  43,   6,   1,   8,  15,  26,  29,  20,  19,
    174, 169, 160, 167, 178, 181, 188, 187, 150, 145, 152, 159, 138, 141, 132, 131,
    222, 217, 208, 215, 194, 197, 204, 203, 230, 225, 232, 239, 250, 253, 244, 243
]

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
    @Published var isSyncing        : Bool         = false
    @Published var syncProgress     : String       = ""

    // MARK: - CoreBluetooth
    private var centralManager    : CBCentralManager!
    private var whoopPeripheral   : CBPeripheral?
    private var cmdCharacteristic : CBCharacteristic?
    private var pingTimer         : Timer?

    /// Stored peripheral UUID so we can reconnect without re-scanning
    private var storedPeripheralID: UUID?

    /// Called by onFrame when a HISTORY_END metadata arrives — drives the sync protocol
    private var historyEndContinuation: CheckedContinuation<UInt32, Never>?

    // MARK: - Frame reassembly
    private let reassembler = FrameReassembler()

    // MARK: - Networking
    private let network = NetworkManager()

    // MARK: - Init
    override init() {
        // Restore last-known peripheral UUID for fast reconnect
        if let uuidStr = UserDefaults.standard.string(forKey: "whoop_peripheral_uuid"),
           let uuid = UUID(uuidString: uuidStr) {
            storedPeripheralID = uuid
        }
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)

        // Wire up reassembler → ingest pipeline
        reassembler.onFrame = { [weak self] frameBytes in
            guard let self else { return }

            let pktType = frameBytes.count > 4 ? frameBytes[4] : 0

            // 0x31 = METADATA — drives the historical sync handshake, NOT forwarded to backend
            if pktType == 0x31 {
                let metaType = frameBytes.count > 5 ? frameBytes[5] : 0
                switch metaType {
                case 2: // HISTORY_END — extract trim and send acknowledgment
                    if frameBytes.count >= 21 {
                        let trim = UInt32(frameBytes[17])
                            | (UInt32(frameBytes[18]) << 8)
                            | (UInt32(frameBytes[19]) << 16)
                            | (UInt32(frameBytes[20]) << 24)
                        self.appendLog(.system, "📬 HISTORY_END trim=\(trim)")
                        self.historyEndContinuation?.resume(returning: trim)
                        self.historyEndContinuation = nil
                    }
                case 3: // HISTORY_COMPLETE — sync finished
                    self.appendLog(.system, "✅ Historical sync complete")
                    DispatchQueue.main.async { self.isSyncing = false; self.syncProgress = "" }
                    self.historyEndContinuation?.resume(returning: 0xFFFFFFFF)
                    self.historyEndContinuation = nil
                default:
                    self.appendLog(.system, "📋 METADATA type=\(metaType)")
                }
                return // Never forward metadata to backend
            }

            // 0x2F = HISTORICAL_DATA — forward to backend exactly like live data
            // 0x2B / 0x28 = live realtime data — forward to backend

            // 0x30 = EVENT
            if pktType == 0x30 {
                let eventType = frameBytes.count > 6 ? frameBytes[6] : 0
                if eventType == 14 {
                    self.appendLog(.system, "👋 DOUBLE TAP DETECTED — triggered action!")
                } else if eventType == 9 {
                    self.appendLog(.system, "⌚ BAND REMOVED FROM WRIST")
                } else if eventType == 10 {
                    self.appendLog(.system, "⌚ BAND PLACED ON WRIST")
                }
            }

            // Send raw bytes over UDP — no serialization overhead
            self.network.ingestUDP(bytes: frameBytes)

            // For UI only: convert to hex to display in the packet ring buffer
            let hexPayload = frameBytes.map { String(format: "%02X", $0) }.joined()
            self.appendLog(.data, "🧩 Frame[0x\(String(format:"%02X",pktType))] → \(hexPayload.prefix(32))…")

            DispatchQueue.main.async {
                if self.sensorPackets.count >= 300 { self.sensorPackets.removeFirst() }
                self.sensorPackets.append(SensorPacket(hex: hexPayload))
            }
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
        // Fast-path: try to reconnect directly to the last known peripheral
        if let uuid = storedPeripheralID {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                appendLog(.system, "⚡️ Fast-reconnect to cached peripheral — skipping scan")
                connectionStatus    = "Connecting…"
                isScanning          = false
                whoopPeripheral     = p
                p.delegate          = self
                centralManager.connect(p, options: nil)
                return
            }
        }
        // Slow-path: full BLE scan
        logEntries.removeAll()
        sensorPackets.removeAll()
        heartRate    = nil
        batteryLevel = nil
        reassembler.reset()
        connectionStatus = "Scanning…"
        isScanning       = true
        appendLog(.system, "Scanning for Whoop…")
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
        guard let p = whoopPeripheral, let char = cmdCharacteristic,
              p.state == .connected else {
            appendLog(.system, "Cannot sync: Not connected or CMD characteristic missing.")
            return
        }
        guard !isSyncing else {
            appendLog(.system, "Sync already in progress")
            return
        }
        Task { await runHistoricalSync(peripheral: p, char: char) }
    }

    /// Full historical sync loop — mirrors whoomp.js downloadHistoryInternal().
    /// Sends SEND_HISTORICAL_DATA, then loops responding to HISTORY_END metadata
    /// until HISTORY_COMPLETE is received.
    private func runHistoricalSync(peripheral: CBPeripheral, char: CBCharacteristic) async {
        await MainActor.run { isSyncing = true; syncProgress = "Starting historical sync…" }
        appendLog(.system, "⏳ Historical sync started (SEND_HISTORICAL_DATA)")

        // Send initial SEND_HISTORICAL_DATA (cmd=0x16)
        let startPkt = buildPacket(seq: 0x99, cmd: 0x16, payload: [0x00])
        peripheral.writeValue(startPkt, for: char, type: .withResponse)

        var batchCount = 0
        while true {
            // Wait for the next HISTORY_END or HISTORY_COMPLETE (max 15s per batch)
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.appendLog(.system, "⏱️ Sync timeout — assuming no more history")
                self?.historyEndContinuation?.resume(returning: 0xFFFFFFFF)
                self?.historyEndContinuation = nil
            }

            let trim = await withCheckedContinuation { (cont: CheckedContinuation<UInt32, Never>) in
                self.historyEndContinuation = cont
            }
            timeoutTask.cancel()

            if trim == 0xFFFFFFFF {
                // HISTORY_COMPLETE sentinel
                await MainActor.run { isSyncing = false; syncProgress = "" }
                appendLog(.system, "✅ Historical sync complete — \(batchCount) batch(es) fetched")
                return
            }

            // Send HISTORICAL_DATA_RESULT (cmd=0x17) acknowledgment:
            //   payload = [0x01] + uint32LE(trim) + uint32LE(0)
            batchCount += 1
            await MainActor.run { syncProgress = "Syncing batch \(batchCount)…" }

            var payload = [UInt8](repeating: 0, count: 9)
            payload[0] = 0x01
            payload[1] = UInt8(trim & 0xFF)
            payload[2] = UInt8((trim >> 8) & 0xFF)
            payload[3] = UInt8((trim >> 16) & 0xFF)
            payload[4] = UInt8((trim >> 24) & 0xFF)
            // payload[5..8] = 0x00 zero padding

            let resultPkt = buildPacket(seq: UInt8(0xB0 &+ UInt8(batchCount & 0xFF)),
                                        cmd: 0x17, payload: payload)
            peripheral.writeValue(resultPkt, for: char, type: .withResponse)
            appendLog(.system, "📤 HISTORICAL_DATA_RESULT batch=\(batchCount) trim=\(trim)")
        }
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
            appendLog(.system, "Bluetooth powered ON — auto-connecting…")
            // Auto-connect on every app launch / Bluetooth enable
            startScan()
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
        storedPeripheralID  = peripheral.identifier
        // Persist UUID so next launch can fast-reconnect without scanning
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "whoop_peripheral_uuid")
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

        // Sequence: wait for characteristic discovery → historical sync → live stream
        Task { [weak self] in
            guard let self else { return }
            // Wait for characteristic discovery & CMD_TO_STRAP to be ready
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s
            guard let p = self.whoopPeripheral, let char = self.cmdCharacteristic,
                  p.state == .connected else { return }

            // 1. Historical sync: dumps all data stored on-strap since last disconnect
            await self.runHistoricalSync(peripheral: p, char: char)

            // 2. Live stream: starts after sync completes (or if strap doesn't support it)
            self.sendLiveStreamTrigger()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "Connection Failed"
        appendLog(.system, "Failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasUnexpected = error != nil
        connectionStatus = "Disconnected"
        cmdCharacteristic = nil
        heartRate        = nil
        backendHR        = nil
        isSyncing        = false
        reassembler.reset()
        historyEndContinuation?.resume(returning: 0xFFFFFFFF)
        historyEndContinuation = nil

        // Stop pinging backend
        pingTimer?.invalidate()
        pingTimer = nil

        appendLog(.system, "Disconnected: \(error?.localizedDescription ?? "clean")")

        // Auto-reconnect on unexpected drops (range loss, etc.)
        // Keep whoopPeripheral reference alive for reconnect attempt.
        if wasUnexpected, let p = whoopPeripheral ?? central.retrievePeripherals(withIdentifiers: storedPeripheralID.map { [$0] } ?? []).first {
            whoopPeripheral = p
            connectionStatus = "Reconnecting…"
            appendLog(.system, "⚡️ Unexpected disconnect — reconnecting in 2s…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                // If still disconnected, attempt reconnect
                if p.state != .connected {
                    self.appendLog(.system, "🔄 Attempting reconnect to \(p.name ?? "Whoop")…")
                    central.connect(p, options: nil)
                }
            }
        } else {
            whoopPeripheral = nil
        }
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
            // Ignored: Standard 2A19 characteristic returns fake 100%.
            // True strap battery is obtained via the 0x23/0x24 command exchange on kCmdFromStrap.
            break

        case kCmdFromStrap:
            let bytes = [UInt8](data)
            // Gen4 COMMAND_RESPONSE layout: AA lenLo lenHi crc8 | type(0x24) seq cmd data...
            // Battery response: type=0x24, cmd=0x1A (GET_BATTERY_LEVEL=26)
            // Battery value: uint16 LE at data[2] (absolute byte[9]), divide by 10.0
            if bytes.count >= 10, bytes[0] == 0xAA, bytes[4] == 0x24, bytes[6] == 0x1A {
                let rawBatt = UInt16(bytes[9]) | (UInt16(bytes[10]) << 8)
                let pct = Int((Double(rawBatt) / 10.0).rounded())
                let clamped = max(0, min(100, pct))
                DispatchQueue.main.async { self.batteryLevel = clamped }
                network.sendBattery(level: clamped)
                appendLog(.system, "🔋 True Strap Battery: \(clamped)%")
            }
            reassembler.append(bytes)

        case kManufacturer:
            if let name = String(data: data, encoding: .utf8) {
                manufacturerName = name
                appendLog(.system, "Manufacturer: \(name)")
            }

        case kWhoopEvents:
            let bytes = [UInt8](data)
            appendLog(.data, "EVENT → \(bytes.count)B")
            network.ingestUDP(bytes: bytes)
            reassembler.append(bytes) // Also forward to reassembler for frame-level callbacks

        case kWhoopData:
            // DATA_FROM_STRAP — high-frequency accel + PPG firehose.
            // BLE MTU (~185 bytes) means large packets (e.g. 1,300-byte R10 IMU)
            // arrive as fragments. Feed each chunk into the FrameReassembler;
            // onFrame fires only when a complete Gen4 frame has been buffered.
            let bytes = [UInt8](data)

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

    /// Sends five Gen4 commands in sequence:
    ///   seq=0xA0  cmd=0x1A  payload=[0x00] → GET_BATTERY_LEVEL (+0ms)
    ///   seq=0xA1  cmd=0x03  payload=[0x01] → Toggle HR          (+300ms)
    ///   seq=0xA2  cmd=0x3F  payload=[0x01] → Send R10 IMU       (+600ms)
    ///   seq=0xA3  cmd=0x6B  payload=[0x01] → ENABLE_OPTICAL_DATA (+900ms)
    ///   seq=0xA4  cmd=0x6C  payload=[0x01] → TOGGLE_OPTICAL_MODE (+1200ms)
    private func sendLiveStreamTrigger() {
        guard let p = whoopPeripheral,
              let char = cmdCharacteristic,
              p.state == .connected else { return }

        var seq: UInt8 = 0xA0

        // Helper: write a packet immediately and bump the sequence counter.
        func send(cmd: UInt8, payload: [UInt8]) {
            let pkt = buildPacket(seq: seq, cmd: cmd, payload: payload)
            p.writeValue(pkt, for: char, type: .withResponse)
            let hex = pkt.map { String(format: "%02X", $0) }.joined()
            appendLog(.system, "📤 cmd=0x\(String(format: "%02X", cmd)) seq=0x\(String(format: "%02X", seq)) → \(hex)")
            seq &+= 1
        }

        // Cmd 0: GET_BATTERY_LEVEL (0x1A=26) — response arrives on kCmdFromStrap with cmd=0x1A
        send(cmd: 0x1A, payload: [0x00])

        // Cmd 1: Toggle HR
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x03, payload: [0x01])
        }
        // Cmd 2: Send R10 IMU
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x3F, payload: [0x01])
        }
        // Cmd 3: ENABLE_OPTICAL_DATA (0x6B=107) — activates optical sensor streaming
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, p.state == .connected else { return }
            send(cmd: 0x6B, payload: [0x01])
        }
        // Cmd 4: SpO2 enable
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
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
        p.writeValue(Data(bytes), for: char, type: .withResponse)
        appendLog(.system, "🔴 Background: sent stop/record command")
    }
}

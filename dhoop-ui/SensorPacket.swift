//
//  SensorPacket.swift
//  dhoop-ui
//

import Foundation
import SwiftUI

enum SensorPacketType: UInt8 {
    case sensorFrame   = 0xF9
    case compressed    = 0x57
    case metadata      = 0x03

    var label: String {
        switch self {
        case .sensorFrame:  return "SENSOR"
        case .compressed:   return "COMP"
        case .metadata:     return "META"
        }
    }

    var color: Color {
        switch self {
        case .sensorFrame:  return .green
        case .compressed:   return .blue
        case .metadata:     return .orange
        }
    }
}

struct SensorPacket: Identifiable {
    let id            = UUID()
    let timestamp     : Date
    let type          : SensorPacketType
    let frameCounter  : UInt16
    let deviceUptimeMs: UInt32
    let payload       : Data    // full payload after AA header

    // Decoded metrics (only present for SyncBatchData packets)
    let parsedHR    : Int?
    let parsedAccel : (x: Float, y: Float, z: Float)?

    /// Hex preview of the sensor body (bytes 12..<len-4, i.e. skip sub-header and CRC)
    var bodyHex: String {
        let start = min(12, payload.count)
        let end   = max(start, payload.count - 4)
        guard start < end else { return "(empty)" }
        return payload[start..<end]
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }

    /// CRC32 from last 4 bytes of payload
    var crc: String {
        guard payload.count >= 4 else { return "" }
        return payload[(payload.count - 4)...]
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// Human-readable uptime
    var uptimeString: String {
        let total = Int(deviceUptimeMs / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Parse a raw BLE Data blob from characteristic 61080004
    init?(data: Data) {
        guard data.count >= 12,
              data[0] == 0xAA else { return nil }

        let length = Int(data[1]) | (Int(data[2]) << 8)
        guard data.count >= 4 + length else { return nil }

        let rawType = data[3]
        type = SensorPacketType(rawValue: rawType) ?? .sensorFrame

        payload = data.subdata(in: 4 ..< (4 + length))
        timestamp = .now

        // Payload layout:
        // [0-1]  frame counter LE uint16
        // [2-3]  sub-flags
        // [4-7]  device uptime ms LE uint32
        frameCounter = payload.count >= 2
            ? UInt16(payload[0]) | (UInt16(payload[1]) << 8)
            : 0

        deviceUptimeMs = payload.count >= 8
            ? UInt32(payload[4]) | (UInt32(payload[5]) << 8)
                | (UInt32(payload[6]) << 16) | (UInt32(payload[7]) << 24)
            : 0

        // SyncBatchData packet: byte 6 == 0x05, minimum 52 bytes
        // Offsets are absolute into the raw characteristic Data value.
        if data.count >= 52, data[6] == 0x05 {
            parsedHR = Int(data[21])

            // Little-endian IEEE-754: assemble UInt32 bit-pattern manually,
            // then reinterpret as Float — safe, no aliasing, endian-explicit.
            func leFloat(at i: Int) -> Float {
                let bits = UInt32(data[i])
                    | (UInt32(data[i + 1]) << 8)
                    | (UInt32(data[i + 2]) << 16)
                    | (UInt32(data[i + 3]) << 24)
                return Float(bitPattern: bits)
            }
            parsedAccel = (x: leFloat(at: 40), y: leFloat(at: 44), z: leFloat(at: 48))
        } else {
            parsedHR    = nil
            parsedAccel = nil
        }
    }
}

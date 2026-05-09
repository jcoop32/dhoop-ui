//
//  SensorPacket.swift
//  dhoop-ui
//

import Foundation
import SwiftUI

struct SensorPacket: Identifiable {
    let id = UUID()
    let timestamp: Date = .now
    let typeLabel: String
    let color: Color
    let bodyHex: String

    init(hex: String) {
        self.bodyHex = hex
        if hex.count >= 10 {
            let typeStr = String(hex.dropFirst(8).prefix(2))
            switch typeStr {
            case "28": typeLabel = "DATA";  color = .blue
            case "30": typeLabel = "EVENT"; color = .orange
            case "31": typeLabel = "META";  color = .purple
            default:   typeLabel = "UNK";   color = .gray
            }
        } else {
            typeLabel = "FRAG"
            color = .red
        }
    }
}

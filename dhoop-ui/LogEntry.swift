//
//  LogEntry.swift
//  dhoop-ui
//
//  Created by Joshua Cooper on 5/7/26.
//

import Foundation

/// Source category of a log entry — drives the badge colour in the UI.
enum LogSource: String {
    case service  = "SERVICE"
    case char     = "CHAR"
    case data     = "DATA"
    case system   = "SYSTEM"
}

struct LogEntry: Identifiable {
    let id        = UUID()
    let timestamp : Date      = .now
    let source    : LogSource
    let detail    : String    // UUID string or hex payload
}

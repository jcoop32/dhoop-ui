//
//  ContentView.swift
//  dhoop-ui
//

import SwiftUI

// MARK: - Root View
struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var selectedTab: Int = 0
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                whoopHeaderView
                
                ZStack {
                    if selectedTab == 0 {
                        HistoryView() // The "Home" Dashboard
                    } else if selectedTab == 1 {
                        liveHRView
                    } else if selectedTab == 2 {
                        logScrollView
                    } else if selectedTab == 3 {
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.bottom, 60) // Make room for tab bar

            whoopTabBar
        }
        .preferredColorScheme(.dark)
    }

    private var whoopHeaderView: some View {
        HStack {
            // Profile Icon
            Image(systemName: "person.crop.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.white)
            
            Spacer()
            
            // Date Pill
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text("TODAY")
                    .font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            
            Spacer()
            
            // Battery & Strap
            if let battery = ble.batteryLevel {
                HStack(spacing: 4) {
                    Text("\(battery)%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(.white)
                        Circle()
                            .fill(battery > 20 ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            } else {
                Image(systemName: "applewatch.slash")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var liveHRView: some View {
        VStack(spacing: 20) {
            heroHRCard
            statsBar
            controlRow
            Spacer()
        }
        .padding(.top, 20)
    }

    // MARK: Heart Rate Hero Card
    private var heroHRCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.red.opacity(0.25), lineWidth: 1))

            HStack(spacing: 24) {
                // Pulsing heart
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulse ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                   value: pulse)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                        .scaleEffect(pulse ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                   value: pulse)
                }
                .onAppear { pulse = true }

                VStack(alignment: .leading, spacing: 4) {
                    Text("HEART RATE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.7))
                        .tracking(2)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(ble.backendHR.map { "\($0)" } ?? "—")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.3), value: ble.backendHR)
                        Text("BPM")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.bottom, 8)
                    }
                    if ble.backendHR != nil {
                        Text("📡 LIVE FROM SERVER")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .tracking(1.5)
                    } else {
                        Text("Waiting for signal…")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Stats Bar
    private var statsBar: some View {
        HStack(spacing: 10) {
            if let battery = ble.batteryLevel {
                statPill(icon: "battery.75", label: "\(battery)%", color: battery > 20 ? .green : .red)
            }
            statPill(icon: "cpu", label: ble.manufacturerName ?? "Whoop", color: .cyan)
            statPill(icon: "waveform.path", label: "\(ble.sensorPackets.count) pkts", color: .purple)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func statPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundColor(color)
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }

    // MARK: Control Row
    private var controlRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.8), radius: 4)
                Text(ble.connectionStatus)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                // Manual retry — only shown when disconnected
                if !ble.connectionStatus.hasPrefix("Connect") && !ble.isScanning {
                    Button(action: { ble.startScan() }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.cyan)
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            .background(Color.cyan.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.white.opacity(0.06)).clipShape(Capsule())

            // Historical sync progress + manual sync button
            HStack(spacing: 8) {
                if ble.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(.purple)
                        Text(ble.syncProgress)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.purple.opacity(0.85))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.purple.opacity(0.1)).clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.purple.opacity(0.25), lineWidth: 1))
                    .transition(.opacity)
                } else {
                    Button(action: { ble.triggerHistoricalSync() }) {
                        Label("Sync History", systemImage: "clock.arrow.2.circlepath")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.purple)
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            .background(Color.purple.opacity(0.1)).clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.purple.opacity(0.3), lineWidth: 1))
                    }
                    .disabled(ble.connectionStatus != "Connected ✓")
                    .opacity(ble.connectionStatus != "Connected ✓" ? 0.3 : 1.0)
                    .transition(.opacity)
                }
                if ble.isScanning {
                    Button(action: { ble.stopScan() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
                            .padding(.vertical, 6).padding(.horizontal, 14)
                            .background(Color.red.opacity(0.1)).clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ble.isSyncing)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ble.isScanning)
        }
        .padding(.vertical, 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ble.connectionStatus)
    }

    // MARK: Tab Strip
    private var whoopTabBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 0) {
                tabButton("HOME",     index: 0, icon: "house.fill")
                tabButton("LIVE",     index: 1, icon: "heart.fill")
                tabButton("LOGS",     index: 2, icon: "terminal.fill")
                tabButton("SETTINGS", index: 3, icon: "gearshape.fill")
            }
            .padding(.top, 12)
            .padding(.bottom, 25) // Safe area spacing
            .background(Color(red: 0.05, green: 0.05, blue: 0.05).ignoresSafeArea())
        }
    }

    private func tabButton(_ title: String, index: Int, icon: String) -> some View {
        Button(action: { selectedTab = index }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(selectedTab == index ? .white : .white.opacity(0.35))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Log Scroll View
    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if ble.logEntries.isEmpty {
                        emptyState(icon: "antenna.radiowaves.left.and.right", text: "Tap Scan & Connect to begin")
                    } else {
                        ForEach(ble.logEntries) { entry in
                            LogRowView(entry: entry).id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: ble.logEntries.count) { _ in
                if let last = ble.logEntries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Sensor Scroll View
    private var sensorScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if ble.sensorPackets.isEmpty {
                        emptyState(icon: "waveform", text: "Sensor packets will appear here once connected")
                    } else {
                        ForEach(ble.sensorPackets) { pkt in
                            SensorPacketRowView(packet: pkt).id(pkt.id)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: ble.sensorPackets.count) { _ in
                if let last = ble.sensorPackets.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Empty State
    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundColor(.white.opacity(0.15))
            Text(text).font(.caption).foregroundColor(.white.opacity(0.25)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: Status Color
    private var statusColor: Color {
        switch ble.connectionStatus {
        case let s where s.hasPrefix("Connected"): return .green
        case let s where s.contains("Fail"):       return .red
        case let s where s.hasPrefix("Scan"),
             let s where s.hasPrefix("Connect"):   return .yellow
        default:                                   return .white.opacity(0.3)
        }
    }
}

// MARK: - Log Row
struct LogRowView: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.30))
                .frame(width: 64, alignment: .leading)
            Text(entry.source.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(badgeColor)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(badgeColor.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(badgeColor.opacity(0.4), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(entry.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(entry.source == .data ? Color(red: 0.4, green: 1, blue: 0.6) : .white.opacity(0.70))
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
    private var badgeColor: Color {
        switch entry.source {
        case .service: return .blue
        case .char:    return .purple
        case .data:    return .green
        case .system:  return .orange
        }
    }
}

// MARK: - Sensor Packet Row
struct SensorPacketRowView: View {
    let packet: SensorPacket
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(packet.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.30))
                .frame(width: 64, alignment: .leading)

            Text(packet.typeLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(packet.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(packet.color.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(packet.color.opacity(0.4), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(packet.bodyHex)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview
#Preview {
    ContentView().environmentObject(BLEManager())
}

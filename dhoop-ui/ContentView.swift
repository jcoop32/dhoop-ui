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
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                headerView
                if ble.connectionStatus.hasPrefix("Connected") {
                    heroHRCard
                    statsBar
                }
                controlRow
                Divider().background(Color.white.opacity(0.08))
                tabStrip
                tabContent
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header
    private var headerView: some View {
        HStack {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundStyle(LinearGradient(colors: [.cyan, .blue],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text("dhoop")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Whoop 4.0 BLE Bridge")
                    .font(.caption).foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            if !ble.logEntries.isEmpty {
                ShareLink(item: ble.exportText(),
                          subject: Text("dhoop BLE Log"),
                          message: Text("Raw BLE scan — \(ble.logEntries.count) entries")) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(8)
                        .background(Color.cyan.opacity(0.12))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
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
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.white.opacity(0.06)).clipShape(Capsule())

            HStack(spacing: 12) {
                Button(action: { ble.startScan() }) {
                    Label("Scan & Connect", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
                        .padding(.vertical, 11).padding(.horizontal, 22)
                        .background(LinearGradient(colors: [.cyan, Color(red: 0.2, green: 0.5, blue: 1)],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(Capsule())
                        .shadow(color: .cyan.opacity(0.35), radius: 8, y: 4)
                }
                .disabled(ble.isScanning || ble.connectionStatus.hasPrefix("Connect"))
                .opacity((ble.isScanning || ble.connectionStatus.hasPrefix("Connect")) ? 0.4 : 1)

                Button(action: { ble.triggerHistoricalSync() }) {
                    Label("Sync Sleep Data", systemImage: "clock.arrow.2.circlepath")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        .padding(.vertical, 11).padding(.horizontal, 22)
                        .background(LinearGradient(colors: [.purple, .indigo],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(Capsule())
                        .shadow(color: .purple.opacity(0.35), radius: 8, y: 4)
                }
                .disabled(ble.connectionStatus != "Connected ✓")
                .opacity(ble.connectionStatus != "Connected ✓" ? 0.4 : 1.0)

                if ble.isScanning {
                    Button(action: { ble.stopScan() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            .padding(.vertical, 11).padding(.horizontal, 18)
                            .background(Color.red.opacity(0.75)).clipShape(Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ble.isScanning)
        }
        .padding(.vertical, 12)
    }

    // MARK: Tab Strip
    private var tabStrip: some View {
        HStack(spacing: 0) {
            tabButton("Log",      index: 0, icon: "list.bullet")
            tabButton("Sensors",  index: 1, icon: "waveform")
            tabButton("Settings", index: 2, icon: "gearshape")
            tabButton("History",  index: 3, icon: "chart.bar.xaxis")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ title: String, index: Int, icon: String) -> some View {
        Button(action: { withAnimation { selectedTab = index } }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(selectedTab == index ? .black : .white.opacity(0.45))
            .padding(.vertical, 7).frame(maxWidth: .infinity)
            .background(selectedTab == index
                ? LinearGradient(colors: [.cyan, Color(red: 0.2, green: 0.5, blue: 1)],
                                 startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [Color.white.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 4)
    }

    // MARK: Tab Content
    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == 0 {
            logScrollView
        } else if selectedTab == 1 {
            sensorScrollView
        } else if selectedTab == 2 {
            SettingsView()
        } else {
            HistoryView()
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

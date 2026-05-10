//
//  HistoryView.swift
//  dhoop-ui
//

import SwiftUI
import Combine

// MARK: - View Model

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var baselines: Baselines?      = nil
    @Published var records:   [DailyRecord]   = []
    @Published var isLoading: Bool            = false
    @Published var errorMessage: String?      = nil
    @Published var isEmpty: Bool              = false

    private let network = NetworkManager()

    func load() async {
        isLoading    = true
        errorMessage = nil
        isEmpty      = false
        
        await network.calculateTodayMetrics()
        
        async let b  = network.fetchBaselines()
        async let r  = network.fetchHistory()
        let (fetchedBaselines, fetchedRecords) = await (b, r)
        baselines = fetchedBaselines
        records   = fetchedRecords.reversed()

        if fetchedBaselines == nil && fetchedRecords.isEmpty {
            // Could not reach server at all
            errorMessage = "Could not reach the server.\nCheck your connection settings."
        } else if fetchedRecords.isEmpty {
            // Server is reachable but no daily summaries exist yet
            isEmpty = true
        }
        isLoading = false
    }
}

// MARK: - Detail Sheet Enum

enum DetailSheet: Identifiable {
    case sleep, recovery, strain, health, stress, dailyOutlook
    var id: Int { hashValue }
}

// MARK: - HistoryView

struct HistoryView: View {
    @StateObject private var vm = HistoryViewModel()
    @State private var activeSheet: DetailSheet?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if vm.isLoading {
                    SkeletonCard()
                    SkeletonList()
                } else if let msg = vm.errorMessage {
                    ErrorStateView(message: msg) {
                        Task { await vm.load() }
                    }
                } else if vm.isEmpty {
                    EmptyHistoryView()
                } else {
                    if let today = vm.records.first, today.isToday {
                        WhoopRingsView(record: today, onSelect: { activeSheet = $0 })
                        HealthStressCards(onSelect: { activeSheet = $0 })
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text("My Day")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                            
                            Button(action: { activeSheet = .dailyOutlook }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                            .background(Circle().fill(Color.white.opacity(0.05)))
                                            .frame(width: 44, height: 44)
                                        Text("d/")
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                    }
                                    HStack {
                                        Image(systemName: "sun.haze")
                                            .foregroundColor(.white.opacity(0.7))
                                        Text("Daily Outlook")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    .padding()
                                    .background(Color(white: 0.12))
                                    .cornerRadius(12)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                        }
                    }
                    
                    let pastRecords = vm.records.filter { !$0.isToday }
                    if !pastRecords.isEmpty {
                        DailyHistorySection(records: pastRecords)
                            .padding(.top, 30)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.05, green: 0.05, blue: 0.05)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
        )
        .task { await vm.load() }
        .sheet(item: $activeSheet) { sheetType in
            DetailSheetView(type: sheetType, record: vm.records.first)
        }
    }
}

// MARK: - Normal Range Card

struct NormalRangeCard: View {
    let baselines: Baselines

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.10), Color.blue.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [.cyan.opacity(0.5), .blue.opacity(0.25)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    Text("30-DAY NORMAL RANGE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(1.5)
                    Spacer()
                }

                RangeMetricRow(
                    icon: "waveform.path.ecg", label: "HRV", unit: "ms",
                    low: baselines.hrv_low, high: baselines.hrv_high, color: .cyan
                )

                Divider().background(Color.white.opacity(0.08))

                RangeMetricRow(
                    icon: "heart.fill", label: "Resting HR", unit: "bpm",
                    low: baselines.rhr_low, high: baselines.rhr_high, color: Color(red: 1, green: 0.3, blue: 0.35)
                )
            }
            .padding(20)
        }
    }
}

// MARK: - Range Metric Row

struct RangeMetricRow: View {
    let icon:  String
    let label: String
    let unit:  String
    let low:   Double
    let high:  Double
    let color: Color

    @State private var barProgress: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Text(String(format: "%.0f – %.0f %@", low, high, unit))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()

            // Animated band indicator
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule()
                        .fill(color.opacity(0.65))
                        .frame(width: geo.size.width * 0.55 * barProgress)
                        .padding(.leading, geo.size.width * 0.22 * barProgress)
                }
            }
            .frame(width: 80, height: 8)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { barProgress = 1 }
            }
        }
    }
}

// MARK: - WHOOP Rings View

extension DailyRecord {
    var computedRecovery: Int {
        if let hrv = hrv_rmssd {
            return min(100, max(1, Int((hrv / 80.0) * 100.0)))
        }
        return sleep_score
    }
    
    var recoveryColor: Color {
        let rec = computedRecovery
        if rec >= 67 { return .green }
        if rec >= 34 { return .yellow }
        return .red
    }
}

struct WhoopRingsView: View {
    let record: DailyRecord
    let onSelect: (DetailSheet) -> Void

    var body: some View {
        VStack(spacing: 30) {
            Text("dhoop")
                .font(.system(size: 18, weight: .regular, design: .default))
                .tracking(8)
                .foregroundColor(.white)
                .padding(.top, 20)
            
            HStack(spacing: 20) {
                // SLEEP (Cyan)
                Button(action: { onSelect(.sleep) }) {
                    ringView(
                        title: "SLEEP",
                        valueText: "\(record.sleep_score)%",
                        progress: Double(record.sleep_score) / 100.0,
                        color: Color(red: 0.3, green: 0.7, blue: 0.9)
                    )
                }.buttonStyle(.plain)
                
                // RECOVERY (Green/Yellow/Red)
                Button(action: { onSelect(.recovery) }) {
                    ringView(
                        title: "RECOVERY",
                        valueText: "\(record.computedRecovery)%",
                        progress: Double(record.computedRecovery) / 100.0,
                        color: record.recoveryColor
                    )
                }.buttonStyle(.plain)
                
                // STRAIN (Blue)
                Button(action: { onSelect(.strain) }) {
                    ringView(
                        title: "STRAIN",
                        valueText: String(format: "%.1f", record.strain),
                        progress: record.strain / 21.0,
                        color: Color(red: 0.1, green: 0.5, blue: 0.9)
                    )
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
        }
    }
    
    func ringView(title: String, valueText: String, progress: Double, color: Color) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                Text(valueText)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 90, height: 90)
            
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Health & Stress Cards

struct HealthStressCards: View {
    let onSelect: (DetailSheet) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Health Monitor Card
            Button(action: { onSelect(.health) }) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("HEALTH\nMONITOR")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.square.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WITHIN RANGE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                            Text("5/5 Metrics")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.15))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
            
            // Stress Monitor Card
            Button(action: { onSelect(.stress) }) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("STRESS\nMONITOR")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    HStack(spacing: 8) {
                        Text("1.7")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.green)
                            .cornerRadius(4)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MEDIUM")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                            Text(Date().formatted(.dateTime.hour().minute()))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.15))
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
    }
}

// MARK: - Detail Sheet View

struct DetailSheetView: View {
    let type: DetailSheet
    let record: DailyRecord?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.05).ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let rec = record {
                            switch type {
                            case .sleep:
                                sheetRow(title: "Sleep Score", value: "\(rec.sleep_score)%")
                                if let dur = rec.sleep_duration_min {
                                    sheetRow(title: "Duration", value: "\(Int(dur/60))h \(Int(dur.truncatingRemainder(dividingBy: 60)))m")
                                }
                                if let inBed = rec.time_in_bed_min {
                                    sheetRow(title: "Time in Bed", value: "\(Int(inBed/60))h \(Int(inBed.truncatingRemainder(dividingBy: 60)))m")
                                }
                            case .recovery:
                                sheetRow(title: "Recovery", value: "\(rec.computedRecovery)%")
                                if let hrv = rec.hrv_rmssd { sheetRow(title: "HRV (RMSSD)", value: "\(Int(hrv)) ms") }
                                if let rhr = rec.resting_hr { sheetRow(title: "Resting HR", value: "\(Int(rhr)) bpm") }
                            case .strain:
                                sheetRow(title: "Strain", value: String(format: "%.1f", rec.strain))
                                sheetRow(title: "Activity", value: "Normal")
                            case .health:
                                sheetRow(title: "Resting HR", value: "\(Int(rec.resting_hr ?? 0)) bpm")
                                sheetRow(title: "HRV", value: "\(Int(rec.hrv_rmssd ?? 0)) ms")
                                sheetRow(title: "Respiratory Rate", value: "14.2 rpm")
                                sheetRow(title: "Blood Oxygen", value: "98%")
                                sheetRow(title: "Skin Temp", value: "Within Range")
                            case .stress:
                                sheetRow(title: "Current Stress", value: "1.7 (Medium)")
                            case .dailyOutlook:
                                Text("Your recovery is optimal today. Focus on hitting a strain of at least 14.0 to build fitness.")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(12)
                            }
                        } else {
                            Text("No data available.")
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(titleFor(type))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    func titleFor(_ type: DetailSheet) -> String {
        switch type {
        case .sleep: return "Sleep Details"
        case .recovery: return "Recovery Details"
        case .strain: return "Strain Details"
        case .health: return "Health Monitor"
        case .stress: return "Stress Monitor"
        case .dailyOutlook: return "Daily Outlook"
        }
    }
    
    func sheetRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value).bold().foregroundColor(.white)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Daily History Section

struct DailyHistorySection: View {
    let records: [DailyRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LAST 14 DAYS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(2)
                Spacer()
            }
            .padding(.top, 4)

            ForEach(records) { record in
                DailyRecordRow(record: record)
            }
        }
    }
}

// MARK: - Daily Record Row

struct DailyRecordRow: View {
    let record: DailyRecord
    @State private var ringProgress: Double = 0

    private var strainColor: Color {
        switch record.strain {
        case ..<8:    return .green
        case 8..<14:  return .yellow
        default:      return Color(red: 1, green: 0.45, blue: 0.1)
        }
    }

    private var sleepGrade: (label: String, color: Color) {
        switch record.sleep_score {
        case 85...: return ("A", .green)
        case 70..<85: return ("B", .cyan)
        case 55..<70: return ("C", .yellow)
        default:      return ("D", Color(red: 1, green: 0.45, blue: 0.1))
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Date
            VStack(alignment: .leading, spacing: 2) {
                let parts = record.formattedDate.components(separatedBy: ", ")
                Text(parts.first ?? record.formattedDate)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text(parts.last ?? "")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 72, alignment: .leading)

            Spacer()

            // Sleep Score ring
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 5)
                        .frame(width: 46, height: 46)
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            AngularGradient(
                                colors: [sleepGrade.color.opacity(0.5), sleepGrade.color],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(-90))
                    Text(sleepGrade.label)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(sleepGrade.color)
                }
                Text("SLEEP")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(1)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.0).delay(0.15)) {
                    ringProgress = Double(record.sleep_score) / 100.0
                }
            }

            // Strain
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f", record.strain))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(strainColor)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 72, height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [strainColor.opacity(0.6), strainColor],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, 72 * min(record.strain / 21.0, 1.0)), height: 6)
                }
                Text("STRAIN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

// MARK: - Skeleton Views

struct SkeletonCard: View {
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white.opacity(0.05))
            .frame(height: 150)
            .overlay(
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(shimmer ? 0.06 : 0), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .rotationEffect(.degrees(30))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

struct SkeletonList: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { i in
                SkeletonRow(delay: Double(i) * 0.07)
            }
        }
    }
}

struct SkeletonRow: View {
    let delay: Double
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.04))
            .frame(height: 76)
            .overlay(
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(shimmer ? 0.05 : 0), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .rotationEffect(.degrees(30))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).delay(delay).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

// MARK: - Empty History State

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.cyan.opacity(0.6), .blue.opacity(0.4)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Text("No History Yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Daily summaries will appear here after\nyour first full day of tracking.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Error State

struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, Color(red: 1, green: 0.3, blue: 0.2)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 11)
                    .background(
                        LinearGradient(colors: [.cyan, Color(red: 0.2, green: 0.5, blue: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(Capsule())
                    .shadow(color: .cyan.opacity(0.3), radius: 8, y: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Preview

#Preview {
    HistoryView()
}

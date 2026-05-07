//
//  SettingsView.swift
//  dhoop-ui
//

import SwiftUI

struct SettingsView: View {

    // Mirror the exact same keys and defaults as DhoopDefaults in NetworkManager.swift
    @AppStorage("dhoop_targetIP")   private var targetIP   = "100.127.237.13"
    @AppStorage("dhoop_targetPort") private var targetPort = "9001"
    @AppStorage("dhoop_apiKey")     private var apiKey     = "dhoop-admin"

    @State private var showCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Header ────────────────────────────────────────────────
                sectionHeader(icon: "network", title: "Ingest Server")

                VStack(spacing: 0) {
                    settingsRow(
                        label: "Target IP",
                        icon:  "server.rack",
                        color: .cyan
                    ) {
                        TextField("e.g. 100.127.237.13", text: $targetIP)
                            .settingsFieldStyle()
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    Divider().background(Color.white.opacity(0.07)).padding(.leading, 52)

                    settingsRow(
                        label: "Port",
                        icon:  "arrow.up.right.circle",
                        color: .blue
                    ) {
                        TextField("e.g. 9001", text: $targetPort)
                            .settingsFieldStyle()
                            .keyboardType(.numberPad)
                    }
                }
                .settingsCardStyle()

                // ── Auth ──────────────────────────────────────────────────
                sectionHeader(icon: "key.horizontal", title: "Authentication")

                VStack(spacing: 0) {
                    settingsRow(
                        label: "API Key",
                        icon:  "lock.shield",
                        color: .purple
                    ) {
                        SecureField("API Key", text: $apiKey)
                            .settingsFieldStyle()
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .settingsCardStyle()

                // ── Preview ───────────────────────────────────────────────
                sectionHeader(icon: "eye", title: "Resolved Endpoint")

                Button {
                    UIPasteboard.general.string = endpointURL
                    withAnimation { showCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showCopied = false }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: showCopied ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(showCopied ? .green : .cyan)
                            .animation(.spring(response: 0.3), value: showCopied)

                        Text(endpointURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // ── Info Footer ───────────────────────────────────────────
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))
                    Text("Changes apply to the next BLE packet — no restart required.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.top, 4)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.08))
    }

    // MARK: - Helpers

    private var endpointURL: String {
        "http://\(targetIP):\(targetPort)/ingest"
    }

    @ViewBuilder
    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .tracking(1.5)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func settingsRow<F: View>(label: String, icon: String, color: Color, @ViewBuilder field: () -> F) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                field()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - View Modifiers

private extension View {
    func settingsFieldStyle() -> some View {
        self
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
    }

    func settingsCardStyle() -> some View {
        self
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Preview
#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}

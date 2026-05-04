import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LoginItemController
    var onRequestNotificationPermission: (() -> Void)?

    @State private var hasRequestedPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                if store.isStale {
                    Text("Stale")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }
                if let model = store.modelName {
                    Text(model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // 5-hour session
            UsageRow(
                label: "Current Session (5hr)",
                percent: store.fiveHourPercent,
                resetsAt: store.fiveHourResetsAt
            )

            // 7-day weekly
            UsageRow(
                label: "Weekly (7 day)",
                percent: store.sevenDayPercent,
                resetsAt: store.sevenDayResetsAt
            )

            Divider()

            // Launch at Login toggle
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .font(.caption)

            // Last updated
            if let updated = store.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for Claude Code data...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Quit
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 280)
        .onAppear {
            loginItem.refresh()
            if !hasRequestedPermission {
                hasRequestedPermission = true
                onRequestNotificationPermission?()
            }
        }
    }
}

// MARK: - Usage Row

struct UsageRow: View {
    let label: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(percent.map { "\(Int($0))%" } ?? "--")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(percentColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(percentColor)
                        .frame(width: max(0, geo.size.width * CGFloat((percent ?? 0) / 100.0)))
                }
            }
            .frame(height: 6)

            // Reset timer
            if let reset = resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var percentColor: Color {
        guard let p = percent else { return .gray }
        if p >= 85 { return .red }
        if p >= 60 { return .orange }
        return .green
    }
}

import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var connection: ClaudeCodeConnection
    var onRequestNotificationPermission: (() -> Void)?

    @State private var hasRequestedPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                if let model = store.modelName {
                    Text(model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Prominent stale banner. We surface this BEFORE the numbers so a
            // user looking at the popover can't miss that the values below are
            // not current. Tied to the same `isStale` flag that puts the `~`
            // on the menu-bar percent.
            if store.isStale && store.hasRateLimitData {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Data may be out of date")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Claude Code hasn't reported new usage recently. Numbers below reflect the last assistant response, and show 0% once a window has reset. Usage from the web, mobile or another machine isn't included.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }

            if connection.state != .connected || connection.message != nil {
                ConnectionPanel(connection: connection)
            }

            // Nothing runs on the user's behalf without being shown here.
            if connection.state == .connected, let chained = connection.chained {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also running your status line")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(chained)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button("Stop Running It") { connection.removeChainedCommand() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if store.hasReceivedData && !store.hasRateLimitData {
                // Status line is wired up but Claude Code isn't surfacing rate
                // limits — almost always means the user is on a plan that
                // doesn't expose them.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rate limits not available")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Tokenz needs a Claude.ai Pro or Max plan. The status line is connected, but rate-limit data isn't being reported.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // 5-hour session
                UsageRow(
                    label: "Current Session (5hr)",
                    percent: store.fiveHourDisplayPercent,
                    resetsAt: store.fiveHourDisplayResetsAt
                )

                // 7-day weekly
                UsageRow(
                    label: "Weekly (7 day)",
                    percent: store.sevenDayDisplayPercent,
                    resetsAt: store.sevenDayDisplayResetsAt
                )

                // Any other limits Claude Code reports (per-model, for instance).
                ForEach(store.visibleExtraLimits) { limit in
                    UsageRow(label: limit.name, percent: limit.percent, resetsAt: limit.resetsAt)
                }

                if store.showsFableHint {
                    Text("Fable has its own weekly limit, which Claude Code doesn't report here. See /usage in Claude Code.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !store.modelShares.isEmpty {
                    ModelBreakdown(shares: store.modelShares, since: store.modelSharesSince)
                }
            }

            Divider()

            // Launch at Login toggle
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .font(.caption)
            .disabled(connection.state == .appNotInstalled)
            if let error = loginItem.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            // Disconnect + Quit
            HStack {
                if connection.state == .connected || connection.state == .needsUpdate {
                    Button("Disconnect from Claude Code") {
                        connection.disconnect()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
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
            connection.refresh(clearingMessage: true)
            store.reloadModelShares()
            if !hasRequestedPermission {
                hasRequestedPermission = true
                onRequestNotificationPermission?()
            }
        }
    }
}

// MARK: - Connection Panel

/// Setup prompt shown until Claude Code's status line points at this app, plus
/// the result of the last Connect / Disconnect.
struct ConnectionPanel: View {
    @ObservedObject var connection: ClaudeCodeConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            if let detail = detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button = buttonTitle {
                Button(button) { connection.connect() }
                    .controlSize(.small)
            }
            if let message = connection.message {
                Text(message)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .cornerRadius(6)
    }

    private var title: String? {
        switch connection.state {
        case .connected: return nil
        case .notConnected: return "Not connected to Claude Code"
        case .needsUpdate: return "Connection needs an update"
        case .otherStatusLine: return "Claude Code already has a status line"
        case .settingsUnreadable: return "Can't read Claude Code's settings"
        case .appNotInstalled: return "Move Tokenz to Applications"
        }
    }

    private var detail: String? {
        switch connection.state {
        case .connected: return nil
        case .notConnected:
            return "Connect adds a status line entry to ~/.claude/settings.json so Claude Code can report your usage. Tokenz keeps a backup of the file."
        case .needsUpdate:
            return "Claude Code is set up with an earlier version of this app (it used to be called ClaudeMonitor) or a copy that has moved. Update points it at this app."
        case .otherStatusLine:
            return "Connect keeps your status line showing and adds Tokenz alongside it. Tokenz keeps a backup of settings.json."
        case .settingsUnreadable:
            return "~/.claude/settings.json isn't valid JSON, or lists statusLine more than once, so Tokenz won't change it. Fix the file, then reopen this window."
        case .appNotInstalled:
            return "Drag Tokenz into your Applications folder and open it from there to connect it to Claude Code."
        }
    }

    private var buttonTitle: String? {
        switch connection.state {
        case .notConnected, .otherStatusLine: return "Connect to Claude Code"
        case .needsUpdate: return "Update Connection"
        case .connected, .settingsUnreadable, .appNotInstalled: return nil
        }
    }
}

// MARK: - Model Breakdown

/// Where the counted usage went, by model. Drawn as one bar split between
/// the models, not as a bar per model: a row of bars with percentages right
/// under the limit rows reads as more limits, and these are shares of usage.
struct ModelBreakdown: View {
    let shares: [UsageStore.ModelShare]
    /// When counting began, if known.
    let since: Date?

    /// One color per segment, in order. Deliberately not the green / orange /
    /// red the limit rows use.
    private static let palette: [Color] = [.blue, .purple, .teal, .indigo, .gray]

    private func color(_ index: Int) -> Color {
        Self.palette[min(index, Self.palette.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Where your usage went")
                .font(.subheadline)

            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                        Rectangle()
                            .fill(color(index))
                            .frame(width: segmentWidth(share.share, in: geo.size.width))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 2) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(index))
                            .frame(width: 6, height: 6)
                        Text("\(share.name) \(Self.percent(share.share))")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }

            Text(caption)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Width of one segment of the split bar, leaving room for the 1-point
    /// gaps and keeping a sliver visible for a model with a tiny share.
    private func segmentWidth(_ share: Double, in total: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(0, shares.count - 1))
        return max(2, (total - gaps) * CGFloat(share))
    }

    /// Shares are rounded to the nearest percent (unlike limits, which round
    /// down), with a floor so a real but tiny share doesn't read as 0%.
    private static func percent(_ share: Double) -> String {
        let value = Int((share * 100).rounded())
        return value == 0 && share > 0 ? "<1%" : "\(value)%"
    }

    private var caption: String {
        var text = "Estimated split of your Claude Code usage on this Mac"
        if let since = since {
            let time = since.formatted(date: .omitted, time: .shortened)
            text += Calendar.current.isDateInToday(since)
                ? ", since today \(time)"
                : ", since \(since.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \(time)"
        }
        return text + ". These are shares, not limits."
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
                Text(percent.map(UsageFormat.percent) ?? "—")
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
                Text("Resets in \(reset, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var percentColor: Color {
        guard let p = percent else { return .gray }
        switch UsageStore.UsageLevel(percent: p) {
        case .critical: return .red
        case .warning: return .orange
        case .normal, .unknown: return .green
        }
    }
}

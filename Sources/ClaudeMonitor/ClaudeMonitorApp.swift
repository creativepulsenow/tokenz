import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: appDelegate.store,
                loginItem: appDelegate.loginItem,
                onRequestNotificationPermission: { [weak appDelegate] in
                    appDelegate?.alertManager.requestPermissionIfNeeded()
                }
            )
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar label. Displays a colored circle + usage percentage.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundColor(iconColor)
            Text(store.menuBarText)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var iconColor: Color {
        switch store.usageLevel {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}

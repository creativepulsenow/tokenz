import SwiftUI

/// Entry point. The same binary is both the menu bar app and, with
/// `--statusline`, the command Claude Code runs to report usage.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--statusline") {
            StatusLineCommand.run()
            return
        }
        TokenzApp.main()
    }
}

struct TokenzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: appDelegate.store,
                loginItem: appDelegate.loginItem,
                connection: appDelegate.connection,
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

/// The menu bar label: an asterisk colored by usage level, then the
/// bracketed percent and countdown.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            // SF Symbol `asterisk`: evocative of Claude's mark without
            // bundling Anthropic's actual trademark.
            Image(nsImage: icon)
            // A single Text: MenuBarExtra reliably renders only the first
            // Text in its label, so percent and countdown are composed into
            // one string in UsageStore.menuBarFullText.
            Text(store.menuBarFullText)
                .font(.system(.caption, design: .monospaced))
        }
    }

    /// The menu bar draws SwiftUI symbols as templates and drops their tint,
    /// so the color has to be baked into a non-template image. With no usage
    /// level to show, a template image follows the menu bar's own color.
    private var icon: NSImage {
        let color: NSColor?
        switch store.usageLevel {
        case .normal: color = .systemGreen
        case .warning: color = .systemOrange
        case .critical: color = .systemRed
        case .unknown: color = nil
        }
        var configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        if let color = color {
            configuration = configuration.applying(.init(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude usage")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }
}

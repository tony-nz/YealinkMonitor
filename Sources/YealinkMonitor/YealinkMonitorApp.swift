import SwiftUI
import YMCSKit

@main
struct YealinkMonitorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
                // Belt and braces. `start()` is idempotent, and the label's
                // task below is the one that normally wins the race.
                .task { await model.start() }
        } label: {
            MenuBarLabel(model: model)
                // Monitoring has to begin at launch, not at first click.
                //
                // With `.menuBarExtraStyle(.window)` the popover's content is
                // built lazily, the first time the menu is opened -- so a
                // `.task` there means a Mac that boots and is left alone never
                // polls at all, and the menu bar shows a cheerful nothing while
                // the fleet is down. The label is rendered immediately to draw
                // the status item, so its task fires at launch.
                .task { await model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Phones", id: DevicesWindowID) {
            DevicesWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 640)

        Window("Activity", id: ActivityWindowID) {
            ActivityWindow()
                .environment(model)
                .frame(minWidth: 820, minHeight: 420)
        }
        .defaultSize(width: 1000, height: 600)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The menu bar item itself. It has to be readable at a glance and honest about
/// not knowing: a green tick while the last three polls failed would be a lie.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if count > 0 { Text("\(count)") }
        }
    }

    private var count: Int { model.problems.count }

    private var symbol: String {
        if !model.settings.isConfigured { return "phone.badge.plus" }
        if let failure = model.snapshot.failure, failure.needsAttention { return "phone.badge.waveform" }
        if model.isStale || !model.isOnNetwork { return "phone.badge.clock" }
        return count > 0 ? "phone.down.fill" : "phone.fill"
    }
}

import SwiftUI
import YMCSKit

@main
struct YealinkMonitorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
                .task { await model.start() }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Phones", id: DevicesWindowID) {
            DevicesWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 640)

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

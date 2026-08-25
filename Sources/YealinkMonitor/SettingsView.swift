import SwiftUI
import YMCSKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "key") }
            PollingSettings()
                .tabItem { Label("Polling", systemImage: "timer") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(width: 480)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var hasEditedSecret = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Client ID", text: $model.settings.clientID)
                SecureField("Client Secret", text: $secret, prompt: Text(secretPrompt))
                    .onChange(of: secret) { hasEditedSecret = true }
                Picker("Region", selection: $model.settings.region) {
                    ForEach(Region.allCases, id: \.self) { region in
                        Text("\(region.displayName) — \(region.host)").tag(region)
                    }
                }
            } header: {
                Text("YMCS credentials")
            } footer: {
                Text("YMCS issues one Client ID and Secret per enterprise. Generating a new pair may break other integrations that use the same credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save & Test Connection") { save(probing: true) }
                        .buttonStyle(.borderedProminent)
                    if case .checking = model.connectionCheck {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                result
            } footer: {
                Text("Testing tries your selected region first, then the others. A wrong region and a wrong secret both return the same authentication error, so this is the only way to tell them apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private var secretPrompt: String {
        model.hasStoredSecret ? "Stored in keychain — type to replace" : "Required"
    }

    @ViewBuilder
    private var result: some View {
        switch model.connectionCheck {
        case .idle, .checking:
            EmptyView()
        case .succeeded(let region):
            Label("Connected to \(region.host)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    private func save(probing: Bool) {
        if hasEditedSecret && !secret.isEmpty {
            model.saveSecret(secret)
            secret = ""
            hasEditedSecret = false
        }
        Task { await model.checkConnection(probingRegions: probing) }
    }
}

private struct PollingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Check every", selection: $model.settings.heartbeatSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Full refresh every", selection: $model.settings.fullRefreshSeconds) {
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("30 minutes").tag(1800)
                    Text("1 hour").tag(3600)
                }
                Picker("Monitor", selection: $model.settings.deviceTypeFilter) {
                    Text("All devices").tag(DeviceType?.none)
                    Text("Phones only").tag(DeviceType?.some(.phone))
                    Text("Room devices only").tag(DeviceType?.some(.room))
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("Each check costs one request. The full device list is fetched only when the number of offline devices changes, or when the full refresh falls due — so a quiet fleet costs about one request per interval, well inside the 50/second YMCS allows your whole enterprise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Devices", value: "\(model.snapshot.devices.count)")
                LabeledContent("Last updated", value: Format.dateTime(model.snapshot.lastSuccess))
                LabeledContent("Last attempt", value: Format.dateTime(model.snapshot.lastAttempt))
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct AlertSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchesAtLogin = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Notify when a phone goes offline", isOn: $model.settings.notificationsEnabled)
                Toggle("Notify when a phone recovers", isOn: $model.settings.notifyOnRecovery)
                    .disabled(!model.settings.notificationsEnabled)
                Picker("Confirm outages over", selection: $model.settings.confirmations) {
                    Text("1 check (no debounce)").tag(1)
                    Text("2 checks").tag(2)
                    Text("3 checks").tag(3)
                    Text("5 checks").tag(5)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("A phone must be seen offline this many checks in a row before you are told. Recovery is always reported on the first check that sees it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Picker("From", selection: $model.settings.quietHoursStart) { hours }
                Picker("Until", selection: $model.settings.quietHoursEnd) { hours }
                if !model.settings.quietHoursEnabled {
                    Text("Quiet hours are off while these match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Open at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, value in model.setLaunchesAtLogin(value) }
                if !model.settings.mutedDeviceIDs.isEmpty {
                    LabeledContent("Muted devices", value: "\(model.settings.mutedDeviceIDs.count)")
                    Button("Unmute All") { model.settings.mutedDeviceIDs.removeAll() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { launchesAtLogin = model.launchesAtLogin }
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(String(format: "%02d:00", hour)).tag(hour)
        }
    }
}

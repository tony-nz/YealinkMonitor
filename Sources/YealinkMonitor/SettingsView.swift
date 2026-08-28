import SwiftUI
import SMTPKit
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
            EmailSettings()
                .tabItem { Label("Email", systemImage: "envelope") }
            ScheduleSettings()
                .tabItem { Label("Schedules", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520)
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
                LabeledContent("Devices", value: deviceCountText)
                LabeledContent("Last updated", value: Format.dateTime(model.snapshot.lastSuccess))
                LabeledContent("Last attempt", value: Format.dateTime(model.snapshot.lastAttempt))
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// Counts phones in service, and says so when some are not.
    private var deviceCountText: String {
        let archived = model.archivedDevices.count
        guard archived > 0 else { return "\(model.activeDevices.count)" }
        return "\(model.activeDevices.count) (\(archived) archived)"
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
                Picker("Settle for", selection: $model.settings.rebootSettlingSeconds) {
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
            } header: {
                Text("After a restart")
            } footer: {
                Text("A phone you restart from this app drops and comes back, which looks exactly like an outage. For this long afterwards the drop is recorded but not alerted. A phone that has not returned when the time is up is reported as a real outage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, value in model.setLaunchesAtLogin(value) }
                if !model.settings.mutedDeviceIDs.isEmpty {
                    LabeledContent("Muted devices", value: "\(model.settings.mutedDeviceIDs.count)")
                    Button("Unmute All") { model.settings.mutedDeviceIDs.removeAll() }
                }
                if !model.settings.archivedDeviceIDs.isEmpty {
                    LabeledContent("Archived devices", value: "\(model.settings.archivedDeviceIDs.count)")
                    Button("Restore All") { model.settings.archivedDeviceIDs.removeAll() }
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

private struct EmailSettings: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var recipients = ""
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Email me when a phone goes offline", isOn: $model.settings.emailEnabled)
                TextField("Send to", text: $recipients, prompt: Text("ops@example.com, oncall@example.com"))
                    .onSubmit(commitRecipients)
                    .onChange(of: recipients) { commitRecipients() }
                TextField("From", text: $model.settings.emailFrom, prompt: Text("alerts@example.com"))
            } header: {
                Text("Email alerts")
            } footer: {
                Text("Separate several recipients with commas. The From address usually has to be one the mail server is willing to send as.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Server", text: $model.settings.smtpHost, prompt: Text("smtp.example.com"))
                Picker("Security", selection: $model.settings.smtpEncryption) {
                    ForEach(SMTPEncryption.allCases, id: \.self) { encryption in
                        Text(encryption.displayName).tag(encryption)
                    }
                }
                .onChange(of: model.settings.smtpEncryption) { _, encryption in
                    // The port almost always follows the security setting, and a
                    // mismatched pair fails in a way that is hard to read.
                    model.settings.smtpPort = encryption.defaultPort
                }
                TextField("Port", value: $model.settings.smtpPort, format: .number.grouping(.never))
                TextField("Username", text: $model.settings.smtpUsername, prompt: Text("Leave empty for no login"))
                SecureField("Password", text: $password, prompt: Text(passwordPrompt))
                    .onSubmit(commitPassword)
            } header: {
                Text("Mail server")
            } footer: {
                Text("Most providers use STARTTLS on port 587. The password is stored in your login keychain and is never sent over an unencrypted connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Batch changes for", selection: $model.settings.emailWindowSeconds) {
                    Text("Send immediately").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                Picker("At most", selection: $model.settings.emailMaximumPerHour) {
                    Text("4 emails per hour").tag(4)
                    Text("12 emails per hour").tag(12)
                    Text("30 emails per hour").tag(30)
                    Text("60 emails per hour").tag(60)
                }
                Toggle("Email when a phone recovers", isOn: $model.settings.emailOnRecovery)
                Toggle("Apply quiet hours to email", isOn: $model.settings.emailRespectsQuietHours)
            } header: {
                Text("Volume")
            } footer: {
                Text("One network fault can take a whole site offline at once. Batching turns that into a single email instead of one per phone. Over the hourly limit, alerts are held and sent together rather than dropped.\n\nQuiet hours are off for email by default: overnight is usually when you most want to be told.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Send Test Email") { sendTest() }
                        .disabled(!model.settings.isEmailConfigured || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let testResult {
                    Label(testResult, systemImage: testResult == successMessage ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(testResult == successMessage ? .green : .red)
                        .font(.callout)
                }
                if let lastError = model.email.lastError, testResult == nil {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let lastSent = model.email.lastSentAt {
                    LabeledContent("Last sent", value: Format.dateTime(lastSent))
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { recipients = model.settings.emailRecipients.joined(separator: ", ") }
        .onDisappear { commitPassword() }
    }

    private let successMessage = "Sent. Check the inbox."

    private var passwordPrompt: String {
        model.hasStoredSMTPPassword ? "Stored in keychain — type to replace" : "Required by most servers"
    }

    private func commitRecipients() {
        model.settings.emailRecipients = recipients
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commitPassword() {
        guard !password.isEmpty else { return }
        model.saveSMTPPassword(password)
        password = ""
    }

    private func sendTest() {
        commitRecipients()
        commitPassword()
        isTesting = true
        testResult = nil
        Task {
            let failure = await model.email.sendTest(settings: model.settings)
            isTesting = false
            testResult = failure ?? successMessage
        }
    }
}

import SwiftUI
import YMCSKit

/// Scheduled restarts: the list, and the editor behind it.
struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RebootSchedule?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                // Said here rather than buried in a footer, because it is the
                // single most important thing to know about this feature.
                Label(
                    "Schedules only run while this app is running and the Mac is awake. A closed laptop at 3am restarts nothing.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Section {
                if model.settings.rebootSchedules.isEmpty {
                    Text("No schedules. Add one to restart a fixed set of phones at a set time.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach($model.settings.rebootSchedules) { $schedule in
                        ScheduleRow(schedule: $schedule) { editing = schedule }
                    }
                }
                HStack {
                    Button("Add Schedule…") {
                        editing = RebootSchedule(name: "Nightly restart")
                    }
                    Spacer()
                }
            } header: {
                Text("Schedules")
            }

            Section {
                Picker("Run late by up to", selection: $model.settings.scheduleGraceMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            } footer: {
                Text("If the Mac was asleep at the scheduled time, the restart runs when it wakes — but only within this window. Later than that it is recorded as skipped, because a restart hours after you asked for it is a surprise outage rather than a helpful catch-up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule) { saved in
                if let index = model.settings.rebootSchedules.firstIndex(where: { $0.id == saved.id }) {
                    model.settings.rebootSchedules[index] = saved
                } else {
                    model.settings.rebootSchedules.append(saved)
                }
            } onDelete: { id in
                model.settings.rebootSchedules.removeAll { $0.id == id }
            }
            .environment(model)
        }
    }
}

private struct ScheduleRow: View {
    @Binding var schedule: RebootSchedule
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $schedule.isEnabled)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name.isEmpty ? "Untitled" : schedule.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let outcome = schedule.lastOutcome {
                    Text(Self.outcomeText(outcome, at: schedule.lastFired))
                        .font(.caption)
                        .foregroundStyle(outcome.isFailure ? .red : .secondary)
                }
            }
            Spacer()
            Button("Edit…", action: edit)
        }
    }

    private var subtitle: String {
        var parts = [
            String(format: "%02d:%02d", schedule.hour, schedule.minute),
            ScheduleEditor.weekdaySummary(schedule.weekdays),
            "\(schedule.deviceIDs.count) phone\(schedule.deviceIDs.count == 1 ? "" : "s")",
        ]
        if let next = schedule.nextFireDate(after: Date()) {
            parts.append("next \(Format.dateTime(next))")
        }
        return parts.joined(separator: " · ")
    }

    /// The last outcome is shown on the row itself so a schedule that has been
    /// quietly skipping every night is visible without opening anything.
    private static func outcomeText(_ outcome: RebootSchedule.Outcome, at date: Date?) -> String {
        let when = date.map { Format.dateTime($0) } ?? "—"
        switch outcome {
        case .fired(let total, let succeeded, let failed):
            return failed > 0
                ? "\(when): \(succeeded) of \(total) restarted, \(failed) failed"
                : "\(when): restarted \(total)"
        case .firedLate(let minutes):
            return "\(when): ran \(minutes) min late"
        case .skipped(let reason):
            return "\(when): skipped — \(reason)"
        case .failed(let message):
            return "\(when): failed — \(message)"
        }
    }
}

/// The editor. Confirmation happens here, at authoring time, because nobody is
/// present when the schedule actually fires.
private struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var schedule: RebootSchedule
    @State private var search = ""
    let onSave: (RebootSchedule) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The top half is a Form; the phone list deliberately is not.
            //
            // A List nested inside a Form does not scroll on macOS -- the Form
            // owns the scrolling and the inner list just clips -- so a fleet of
            // any size was unreachable past the first few rows.
            Form {
                Section {
                    TextField("Name", text: $schedule.name)
                    HStack {
                        Picker("At", selection: $schedule.hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .frame(width: 120)
                        Picker("", selection: $schedule.minute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) {
                                Text(String(format: "%02d", $0)).tag($0)
                            }
                        }
                        .frame(width: 90)
                        Spacer()
                    }
                    weekdayPicker
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)

            Divider()
            phonePicker

            Divider()
            HStack {
                if model.settings.rebootSchedules.contains(where: { $0.id == schedule.id }) {
                    Button("Delete", role: .destructive) {
                        onDelete(schedule.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(schedule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(schedule.deviceIDs.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 620)
    }

    private var phonePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Phones (\(schedule.deviceIDs.count) selected)")
                    .font(.headline)
                Spacer()
                Button(selectAllTitle) { selectAll() }
                    .disabled(filteredDevices.isEmpty || allFilteredSelected)
                Button("Deselect All") { deselectAll() }
                    .disabled(noneFilteredSelected)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            TextField("Filter", text: $search, prompt: Text("Name or MAC"))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredDevices) { device in
                        Toggle(isOn: binding(for: device)) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(device.displayName)
                                        // Shown rather than filtered out: a
                                        // schedule that already names an
                                        // archived phone must stay visible and
                                        // removable, not silently vanish from
                                        // the list it was chosen in.
                                        if model.isArchived(device) {
                                            Image(systemName: "archivebox")
                                                .foregroundStyle(.secondary)
                                                .help("Archived")
                                        }
                                    }
                                    Text(Device.formatMAC(device.mac))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusBadge(status: device.deviceStatus, showsLabel: false)
                            }
                            // The whole row is the target, not just the label.
                            .contentShape(Rectangle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        Divider().padding(.leading, 16)
                    }
                    if filteredDevices.isEmpty {
                        Text(model.snapshot.devices.isEmpty ? "No phones known yet." : "No phones match that filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if !missingDeviceIDs.isEmpty {
                    Label(
                        "\(missingDeviceIDs.count) saved phone\(missingDeviceIDs.count == 1 ? "" : "s") no longer appear in YMCS. They are kept, not silently dropped.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("Phones are saved individually rather than by site or filter. A schedule defined by a filter would silently grow as phones are added, which is how a restart nobody asked for reaches the whole fleet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Bulk selection

    /// Select and deselect act on what is *shown*, not on the whole fleet.
    /// With a filter typed, "Select All (12)" that quietly selected 400 phones
    /// would be the worst possible surprise in this particular dialog.
    private var selectAllTitle: String {
        search.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Select All"
            : "Select All (\(filteredDevices.count))"
    }

    private var allFilteredSelected: Bool {
        !filteredDevices.isEmpty && filteredDevices.allSatisfy { schedule.deviceIDs.contains($0.id) }
    }

    private var noneFilteredSelected: Bool {
        !filteredDevices.contains { schedule.deviceIDs.contains($0.id) }
    }

    private func selectAll() {
        let existing = Set(schedule.deviceIDs)
        schedule.deviceIDs.append(contentsOf: filteredDevices.map(\.id).filter { !existing.contains($0) })
    }

    /// Only clears what is shown, so a filtered clear cannot wipe selections the
    /// user cannot currently see.
    private func deselectAll() {
        let shown = Set(filteredDevices.map(\.id))
        schedule.deviceIDs.removeAll { shown.contains($0) }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            Text("On").foregroundStyle(.secondary)
            ForEach(1...7, id: \.self) { weekday in
                Toggle(Self.shortWeekdayNames[weekday - 1], isOn: weekdayBinding(weekday))
                    .toggleStyle(.button)
            }
            Spacer()
        }
        .help("Select none for every day")
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.weekdays.isEmpty || schedule.weekdays.contains(weekday) },
            set: { isOn in
                // An empty set means every day, so the first click has to
                // materialise the full set before removing one from it.
                var days = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
                if isOn { days.insert(weekday) } else { days.remove(weekday) }
                schedule.weekdays = days.count == 7 ? [] : days
            }
        )
    }

    private func binding(for device: Device) -> Binding<Bool> {
        Binding(
            get: { schedule.deviceIDs.contains(device.id) },
            set: { isOn in
                if isOn {
                    if !schedule.deviceIDs.contains(device.id) { schedule.deviceIDs.append(device.id) }
                } else {
                    schedule.deviceIDs.removeAll { $0 == device.id }
                }
            }
        )
    }

    private var filteredDevices: [Device] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.snapshot.devices }
        let bare = query.filter(\.isHexDigit).lowercased()
        return model.snapshot.devices.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || (!bare.isEmpty && $0.mac.lowercased().contains(bare))
        }
    }

    private var missingDeviceIDs: [String] {
        let known = Set(model.snapshot.devices.map(\.id))
        return schedule.deviceIDs.filter { !known.contains($0) }
    }

    static let shortWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func weekdaySummary(_ weekdays: Set<Int>) -> String {
        guard !weekdays.isEmpty, weekdays.count < 7 else { return "every day" }
        return weekdays.sorted().map { shortWeekdayNames[$0 - 1] }.joined(separator: " ")
    }
}

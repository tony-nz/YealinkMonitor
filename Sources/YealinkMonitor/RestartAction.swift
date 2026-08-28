import SwiftUI
import YMCSKit

/// A pending request to restart some phones, awaiting confirmation.
///
/// `scope` describes in words where the list came from -- "Site: Wellington,
/// Status: offline" -- because the dangerous version of a bulk restart is the
/// one fired against a filter the user has forgotten is applied.
struct RestartRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case devices([Device])
        /// Accessories on one phone. Restarting these does not drop the phone,
        /// so the warnings are different.
        case accessories(Device, [Accessory])
    }

    let id = UUID()
    let target: Target
    var scope: String?

    init(_ devices: [Device], scope: String? = nil) {
        self.target = .devices(devices)
        self.scope = scope
    }

    init(accessoriesOn device: Device, parts: [Accessory]) {
        self.target = .accessories(device, parts)
    }

    var devices: [Device] {
        switch target {
        case .devices(let devices): devices
        case .accessories(let device, _): [device]
        }
    }
}

extension View {
    /// Confirms, restarts, and reports. Every entry point goes through this, so
    /// there is exactly one place where a restart can be triggered and exactly
    /// one wording of the warning.
    func restartConfirmation(_ request: Binding<RestartRequest?>) -> some View {
        modifier(RestartConfirmation(request: request))
    }
}

private struct RestartConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: RestartRequest?
    @State private var report: AppModel.RebootReport?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                presenting: request
            ) { pending in
                Button("Restart", role: .destructive) { perform(pending) }
                Button("Cancel", role: .cancel) { request = nil }
            } message: { pending in
                Text(detail(pending))
            }
            .alert(
                report?.title ?? "",
                isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } }),
                presenting: report
            ) { _ in
                Button("OK") { report = nil }
            } message: { finished in
                Text(finished.message)
            }
    }

    private var title: String {
        guard let request else { return "" }
        switch request.target {
        case .accessories(let device, let parts):
            return parts.isEmpty
                ? "Restart all accessories on \(device.displayName)?"
                : "Restart \(parts.count) accessor\(parts.count == 1 ? "y" : "ies")?"
        case .devices(let devices):
            return devices.count == 1
                ? "Restart \(devices[0].displayName)?"
                : "Restart \(devices.count) phones?"
        }
    }

    private func detail(_ request: RestartRequest) -> String {
        if case .accessories(let device, let parts) = request.target {
            var lines: [String] = []
            if parts.isEmpty {
                lines.append("Every accessory attached to \(device.displayName) restarts.")
            } else {
                lines.append(parts.map(\.displayName).joined(separator: ", ") + ".")
            }
            // The phone itself keeps running, which is the point of doing this
            // rather than restarting the phone.
            lines.append("The phone itself is not restarted. A headset in use will drop its audio.")
            return lines.joined(separator: "\n\n")
        }

        var lines: [String] = []
        if let scope = request.scope, request.devices.count > 1 {
            lines.append("Matching \(scope).")
        }
        if request.devices.count > 1 {
            let names = request.devices.prefix(5).map(\.displayName).joined(separator: ", ")
            let more = request.devices.count - min(5, request.devices.count)
            lines.append(more > 0 ? "\(names) and \(more) more." : "\(names).")
        }
        // Silently dropping these would be worse: "reboot everything offline"
        // is a natural thing to try and it does nothing at all.
        let unreachable = request.devices.count { $0.deviceStatus != .online }
        if unreachable > 0 {
            lines.append(
                unreachable == request.devices.count
                    ? "None of them are online, so none will receive the command. YMCS will accept it anyway."
                    : "\(unreachable) of them are not online and will not receive the command."
            )
        }
        // The consequence people forget until someone is mid-call.
        lines.append("Each phone that is online drops for a minute or two and any call in progress is cut off.")
        return lines.joined(separator: "\n\n")
    }

    private func perform(_ pending: RestartRequest) {
        request = nil
        Task {
            switch pending.target {
            case .devices(let devices):
                report = await model.reboot(devices)
            case .accessories(let device, let parts):
                report = await model.rebootAccessories(on: device, parts: parts)
            }
        }
    }
}

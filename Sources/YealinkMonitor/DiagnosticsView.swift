import AppKit
import SwiftUI
import YMCSKit

/// Runs the per-device diagnostics and keeps their results.
///
/// Every diagnostic in the API is the same two-step dance -- start it, then poll
/// a ticket until a file appears -- so the waiting, the downloading and the
/// error handling live here once rather than six times in the view.
@MainActor
@Observable
final class DeviceDiagnostics {
    enum Kind: String, CaseIterable, Identifiable {
        case screenshot
        case syslog
        case config
        case ping
        case traceroute
        case packetCapture

        var id: String { rawValue }

        var label: String {
            switch self {
            case .screenshot: "Screenshot"
            case .syslog: "System Log"
            case .config: "Config File"
            case .ping: "Ping…"
            case .traceroute: "Traceroute…"
            case .packetCapture: "Packet Capture…"
            }
        }

        var symbolName: String {
            switch self {
            case .screenshot: "camera.viewfinder"
            case .syslog: "doc.text"
            case .config: "gearshape"
            case .ping: "dot.radiowaves.left.and.right"
            case .traceroute: "point.topleft.down.to.point.bottomright.curvepath"
            case .packetCapture: "waveform.path"
            }
        }

        /// Ping and traceroute produce a few lines of text that are the answer
        /// itself, so they are shown inline. The rest produce files that belong
        /// in Finder.
        var isTextResult: Bool { self == .ping || self == .traceroute }

        /// Only a fallback. What YMCS actually returns is sniffed from the
        /// bytes -- the system log arrives as a zip, not the .txt this would
        /// suggest, and naming a zip .txt produces a file that opens as
        /// gibberish in TextEdit.
        var fallbackExtension: String {
            switch self {
            case .screenshot: "png"
            case .packetCapture: "pcap"
            case .config: "cfg"
            default: "txt"
            }
        }
    }

    struct Job: Identifiable {
        enum State {
            case running(String)
            case text(String)
            case saved(URL)
            case failed(String)
        }

        let id = UUID()
        let kind: Kind
        let detail: String?
        let startedAt: Date
        var state: State
    }

    private(set) var jobs: [Job] = []
    private(set) var interfaces: [String] = []

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool {
        jobs.contains { if case .running = $0.state { true } else { false } }
    }

    func loadInterfaces(for device: Device) async {
        guard interfaces.isEmpty else { return }
        interfaces = (try? await model.makeClient().networkInterfaces(deviceID: device.id)) ?? []
    }

    func start(
        _ kind: Kind,
        on device: Device,
        host: String = "",
        times: Int = 4,
        networkInterface: String = "wan",
        captureType: PacketCaptureType = .notRTP,
        filter: String = "",
        duration: Int = 180
    ) {
        let job = Job(
            kind: kind,
            detail: Self.detail(kind, host: host, networkInterface: networkInterface, duration: duration),
            startedAt: Date(),
            state: .running("Asking the phone…")
        )
        jobs.insert(job, at: 0)

        Task {
            do {
                let client = try model.makeClient()
                let ticket: DiagnosticTicket
                switch kind {
                case .screenshot:
                    ticket = try await client.startScreenshot(deviceID: device.id)
                case .syslog:
                    ticket = try await client.startSyslogExport(deviceID: device.id)
                case .config:
                    ticket = try await client.startConfigExport(deviceID: device.id)
                case .ping:
                    ticket = try await client.startPing(deviceID: device.id, host: host, times: times)
                case .traceroute:
                    ticket = try await client.startTraceroute(deviceID: device.id, host: host, times: times)
                case .packetCapture:
                    ticket = try await client.startPacketCapture(
                        deviceID: device.id,
                        networkInterface: networkInterface,
                        type: captureType,
                        filter: filter.isEmpty ? nil : filter,
                        duration: duration
                    )
                }

                update(job.id, .running(kind == .packetCapture ? "Capturing…" : "Waiting for the phone…"))

                // A capture runs for its full duration by design, so it gets
                // room to finish rather than the default timeout.
                let status = try await client.awaitDiagnostic(
                    id: ticket.diagnosisId,
                    timeout: kind == .packetCapture ? .seconds(duration + 120) : .seconds(300)
                )
                guard let url = status.downloadURL else {
                    update(job.id, .failed("The phone reported the diagnostic as failed."))
                    return
                }
                try await collect(url, for: job, kind: kind, device: device)
            } catch {
                let message = (error as? YMCSError)?.errorDescription ?? error.localizedDescription
                update(job.id, .failed(message))
            }
        }
    }

    /// Text results are read straight into the UI; files are saved where the
    /// user can find them again.
    private func collect(_ url: URL, for job: Job, kind: Kind, device: Device) async throws {
        update(job.id, .running("Downloading…"))
        // The link is a signed, expiring URL on Yealink's storage, so it takes
        // no YMCS credentials and must not be given any.
        let (data, _) = try await URLSession.shared.data(from: url)

        let fileExtension = DiagnosticPayload.fileExtension(for: data, fallback: kind.fallbackExtension)
        // Only render inline when it really is text. A zip decoded as UTF-8
        // would either fail or, worse, half-succeed into mojibake.
        if kind.isTextResult, fileExtension == "txt", let text = String(data: data, encoding: .utf8) {
            update(job.id, .text(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }

        var destination = try Self.save(
            data,
            fileExtension: fileExtension,
            kind: kind,
            device: device,
            at: job.startedAt
        )
        // A log you cannot read without a second step is half a feature.
        if fileExtension == "zip", let expanded = Self.expand(destination) {
            destination = expanded
        }
        update(job.id, .saved(destination))
    }

    /// Expands an archive next to itself and removes it, returning the folder.
    /// Best effort: on any failure the caller keeps the archive, which Finder
    /// can expand on a double click anyway.
    private static func expand(_ archive: URL) -> URL? {
        let destination = archive.deletingPathExtension()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path)
        else { return nil }
        try? FileManager.default.removeItem(at: archive)
        return destination
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clear() {
        jobs.removeAll { if case .running = $0.state { false } else { true } }
    }

    private static func save(
        _ data: Data,
        fileExtension: String,
        kind: Kind,
        device: Device,
        at date: Date
    ) throws -> URL {
        let directory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(sanitised(device.displayName))-\(kind.rawValue)-\(stamp.string(from: date))"

        var candidate = directory.appending(path: "\(base).\(fileExtension)")
        var counter = 2
        // Also checks the extension-less form, since a zip is expanded into a
        // folder of that name and a second export would otherwise collide.
        while FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(atPath: candidate.deletingPathExtension().path) {
            candidate = directory.appending(path: "\(base)-\(counter).\(fileExtension)")
            counter += 1
        }
        try data.write(to: candidate, options: .atomic)
        return candidate
    }

    private static func sanitised(_ name: String) -> String {
        let allowed = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            // Otherwise "Tony (706)" became "Tony-706-" and the assembled name
            // read "Tony-706--syslog".
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func detail(
        _ kind: Kind,
        host: String,
        networkInterface: String,
        duration: Int
    ) -> String? {
        switch kind {
        case .ping, .traceroute: host
        case .packetCapture: "\(networkInterface), \(duration)s"
        default: nil
        }
    }
}

/// The diagnostics section of the device detail pane.
struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @Bindable var diagnostics: DeviceDiagnostics

    @State private var prompt: Prompt?

    /// The two diagnostics that need input before they can run.
    private struct Prompt: Identifiable {
        let id = UUID()
        let kind: DeviceDiagnostics.Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Diagnostics").font(.headline)
                Spacer()
                if !diagnostics.jobs.isEmpty {
                    Button("Clear") { diagnostics.clear() }
                        .font(.caption)
                }
            }

            // Everything here runs *on the phone*, which is the point: it
            // answers questions about the handset's own network that nothing on
            // this Mac can.
            FlowRow {
                ForEach(DeviceDiagnostics.Kind.allCases) { kind in
                    Button {
                        switch kind {
                        case .ping, .traceroute, .packetCapture:
                            prompt = Prompt(kind: kind)
                        default:
                            diagnostics.start(kind, on: device)
                        }
                    } label: {
                        Label(kind.label, systemImage: kind.symbolName)
                    }
                    .disabled(device.deviceStatus != .online)
                }
            }

            if device.deviceStatus != .online {
                Text("The phone is not online, so it cannot run diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(diagnostics.jobs) { job in
                JobRow(job: job) { diagnostics.reveal($0) }
            }
        }
        .sheet(item: $prompt) { prompt in
            DiagnosticPrompt(kind: prompt.kind, interfaces: diagnostics.interfaces) { parameters in
                diagnostics.start(
                    prompt.kind,
                    on: device,
                    host: parameters.host,
                    times: parameters.times,
                    networkInterface: parameters.networkInterface,
                    captureType: parameters.captureType,
                    filter: parameters.filter,
                    duration: parameters.duration
                )
            }
        }
        .task(id: device.id) { await diagnostics.loadInterfaces(for: device) }
    }
}

private struct JobRow: View {
    let job: DeviceDiagnostics.Job
    let reveal: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: job.kind.symbolName)
                    .foregroundStyle(.secondary)
                Text(title).font(.callout)
                Spacer()
                Text(Format.time(job.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch job.state {
            case .running(let stage):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.caption).foregroundStyle(.secondary)
                }
            case .text(let output):
                ScrollView(.horizontal) {
                    Text(output.isEmpty ? "No output." : output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(maxHeight: 160)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            case .saved(let url):
                HStack(spacing: 8) {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") { reveal(url) }
                        .font(.caption)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        guard let detail = job.detail else { return job.kind.label.replacingOccurrences(of: "…", with: "") }
        return "\(job.kind.label.replacingOccurrences(of: "…", with: "")) — \(detail)"
    }
}

/// Input for the diagnostics that need it.
private struct DiagnosticPrompt: View {
    struct Parameters {
        var host = ""
        var times = 4
        var networkInterface = "wan"
        var captureType = PacketCaptureType.notRTP
        var filter = ""
        var duration = 180
    }

    @Environment(\.dismiss) private var dismiss
    let kind: DeviceDiagnostics.Kind
    let interfaces: [String]
    let run: (Parameters) -> Void

    @State private var parameters = Parameters()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if kind == .packetCapture {
                    Picker("Port", selection: $parameters.networkInterface) {
                        ForEach(interfaces.isEmpty ? ["wan"] : interfaces, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Capture", selection: $parameters.captureType) {
                        ForEach(PacketCaptureType.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if parameters.captureType == .custom {
                        TextField("Filter", text: $parameters.filter, prompt: Text("port 5060"))
                    }
                    Picker("For", selection: $parameters.duration) {
                        Text("3 minutes").tag(180)
                        Text("10 minutes").tag(600)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                    }
                    Text("The capture runs on the phone for the whole time before the file is available. Three minutes is the shortest the API allows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Host", text: $parameters.host, prompt: Text("10.0.0.1 or gateway name"))
                    Picker("Times", selection: $parameters.times) {
                        ForEach([1, 4, 10, 30], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text("Runs from the phone, not from this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run") {
                    run(parameters)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(kind != .packetCapture && parameters.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420)
    }
}

/// Wraps buttons onto as many lines as they need. `HStack` would either clip
/// them or force the pane wider than the window.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: width == .infinity ? rowWidth : width, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

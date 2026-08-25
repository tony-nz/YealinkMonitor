import Foundation
@testable import YMCSKit

/// Records every request and replies from a queue of canned responses, so the
/// client can be exercised end to end without a network or credentials.
actor StubTransport: HTTPTransport {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path() }
        func header(_ name: String) -> String? { headers[name] }
        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    /// Decides the reply for a request. Returning nil falls through to `queue`.
    typealias Handler = @Sendable (Recorded) -> HTTPResponse?

    private var queue: [HTTPResponse] = []
    private var handler: Handler?
    private(set) var recorded: [Recorded] = []

    init(handler: Handler? = nil) {
        self.handler = handler
    }

    func enqueue(_ responses: HTTPResponse...) {
        queue.append(contentsOf: responses)
    }

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requestCount: Int { recorded.count }

    func requests(matching path: String) -> [Recorded] {
        recorded.filter { $0.path.hasSuffix(path) }
    }

    nonisolated func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await reply(to: request)
    }

    private func reply(to request: URLRequest) throws -> HTTPResponse {
        let record = Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        recorded.append(record)
        if let handler, let response = handler(record) { return response }
        guard !queue.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        return queue.removeFirst()
    }
}

extension HTTPResponse {
    static func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(string.utf8)
        )
    }

    static func fixture(_ name: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Fixture.data(name))
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            fatalError("missing fixture \(name).json")
        }
        return try! Data(contentsOf: url)
    }
}

extension Credentials {
    static let test = Credentials(clientID: "id", clientSecret: "secret", region: .au)
}

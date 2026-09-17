import Foundation
import Network

struct DiagnosticEnvelope: Codable {
    var diagnostics: [BugDiagnostic]
    var source: String
    var replace: Bool?
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum HTTPParseResult {
    case incomplete
    case invalid(Int)
    case request(HTTPRequest)
}

/// Deliberately excludes input text, diagnostic messages, file paths and history.
/// AppKit/Accessibility reads happen on the main thread before this value is cached.
struct BridgeHealthSnapshot {
    var running = false
    var accessibility = false
    var screen = false
    var textChecking = false
    var checkSpelling = false
    var textStatus = "正在启动文字检查"
    var inputMetadata: [String: String] = [:]
    var writingIssueCount = 0
    var writingTargetCount = 0
    var currentSource: String?
    var flyTarget: ScreenPoint?
    var flyPosition: ScreenPoint?
    var sampledAt = Date().timeIntervalSince1970

    var object: [String: Any] {
        func point(_ value: ScreenPoint?) -> Any {
            guard let value, value.x.isFinite, value.y.isFinite else { return NSNull() }
            return ["x": value.x, "y": value.y]
        }
        return ["ok": true, "app": "FlyBug", "version": "1.2.0",
                "running": running, "accessibility": accessibility, "screen": screen,
                "textChecking": textChecking, "checkSpelling": checkSpelling, "textStatus": textStatus,
                "inputMetadata": inputMetadata,
                "writingIssueCount": writingIssueCount, "writingTargetCount": writingTargetCount,
                "currentSource": currentSource as Any? ?? NSNull(),
                "flyTarget": point(flyTarget), "flyPosition": point(flyPosition),
                "sampledAt": sampledAt]
    }
}

enum HTTPParser {
    static let bodyLimit = 512 * 1024
    static func parse(_ data: Data) -> HTTPParseResult {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16384 ? .invalid(431) : .incomplete
        }
        guard split.lowerBound <= 16384,
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .invalid(400) }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespaces), headers[key] == nil else { return .invalid(400) }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid(400) }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(raw), n <= bodyLimit else { return .invalid(413) }
            length = n
        } else {
            guard request[0] != "POST" else { return .invalid(411) }
            length = 0
        }
        guard data.count >= split.upperBound + length else { return .incomplete }
        // A connection handles exactly one request; reject pipelined/trailing bytes.
        guard data.count == split.upperBound + length else { return .invalid(400) }
        return .request(HTTPRequest(method: String(request[0]), path: String(request[1]), headers: headers,
                                   body: Data(data[split.upperBound...])))
    }

    static func authorized(_ request: HTTPRequest, token: String) -> Bool {
        guard request.headers["origin"] == nil,
              let supplied = request.headers["authorization"] else { return false }
        let a = Array(supplied.utf8), b = Array(("Bearer " + token).utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

final class BridgeServer {
    var onDiagnostics: ((DiagnosticEnvelope) -> Void)?
    var onState: ((Int, String) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "flybug.bridge", qos: .utility)
    private var connections: [UUID: NWConnection] = [:]
    private let token = UUID().uuidString + UUID().uuidString
    private let directory: URL
    private var savedDiscovery = false
    private var stopped = false
    // Accessed exclusively on queue; /health never synchronously enters the UI thread.
    private var health = BridgeHealthSnapshot()
    private(set) var port = 0

    init(directory: URL) { self.directory = directory }

    func updateHealth(_ snapshot: BridgeHealthSnapshot) {
        queue.async { [weak self] in self?.health = snapshot }
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        do {
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = Int(listener.port?.rawValue ?? 0)
                    do {
                        try self.writeDiscovery()
                        DispatchQueue.main.async { self.onState?(self.port, "本地接入已就绪") }
                    } catch {
                        self.fail("无法保存接入信息：\(error.localizedDescription)")
                    }
                case .failed(let error): self.fail("本地接入启动失败：\(error.localizedDescription)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        } catch { fail("本地接入启动失败：\(error.localizedDescription)") }
    }

    private func fail(_ message: String) {
        listener?.cancel()
        DispatchQueue.main.async { self.onState?(0, message) }
    }

    private func writeDiscovery() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier]
        let file = directory.appendingPathComponent("bridge.json")
        // Set restrictive permissions before writing a token; rename the private file atomically.
        let temporary = directory.appendingPathComponent(".bridge-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "FlyBug", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入私有接入文件"])
        }
        if rename(temporary.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        savedDiscovery = true
    }

    func stop() {
        queue.sync {
            stopped = true
            listener?.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            let file = directory.appendingPathComponent("bridge.json")
            if savedDiscovery,
               let data = try? Data(contentsOf: file),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               info["token"] as? String == token { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 24 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id) }
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(id) }
        receive(connection, id: id, buffer: Data())
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self, self.connections[id] != nil else { return }
            var combined = buffer
            if let chunk { combined.append(chunk) }
            if combined.count > HTTPParser.bodyLimit + 16388 { self.respond(connection, id: id, code: 413); return }
            switch HTTPParser.parse(combined) {
            case .incomplete:
                if done || error != nil { self.close(id) }
                else { self.receive(connection, id: id, buffer: combined) }
            case .invalid(let code): self.respond(connection, id: id, code: code)
            case .request(let request): self.handle(request, connection: connection, id: id)
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection, id: UUID) {
        guard HTTPParser.authorized(request, token: token) else { respond(connection, id: id, code: 401); return }
        guard let host = request.headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host) else {
            respond(connection, id: id, code: 403); return
        }
        if request.method == "GET", request.path == "/health" {
            respond(connection, id: id, code: 200, object: health.object)
        } else if request.method == "POST", request.path == "/diagnostics" {
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                  var envelope = try? JSONDecoder().decode(DiagnosticEnvelope.self, from: request.body),
                  !envelope.source.isEmpty, envelope.source.count <= 200, envelope.diagnostics.count <= 50 else {
                respond(connection, id: id, code: 400); return
            }
            for i in envelope.diagnostics.indices {
                let diagnostic = envelope.diagnostics[i]
                guard !diagnostic.id.isEmpty, diagnostic.id.count <= 300,
                      !diagnostic.message.isEmpty, diagnostic.message.count <= 10000,
                      ["error", "warning"].contains(diagnostic.severity),
                      (diagnostic.line ?? 1) > 0, (diagnostic.line ?? 1) < 10000000,
                      (diagnostic.column ?? 1) > 0,
                      (diagnostic.file?.count ?? 0) <= 4096,
                      (diagnostic.lineText?.count ?? 0) <= 20000,
                      diagnostic.target.map({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 100000 && abs($0.y) < 100000 }) ?? true else {
                    respond(connection, id: id, code: 400); return
                }
                envelope.diagnostics[i].source = envelope.source
            }
            DispatchQueue.main.async {
                self.onDiagnostics?(envelope)
                self.queue.async { self.respond(connection, id: id, code: 200, object: ["ok": true]) }
            }
        } else { respond(connection, id: id, code: 404) }
    }

    private func respond(_ connection: NWConnection, id: UUID, code: Int, object: [String: Any]? = nil) {
        guard connections[id] != nil else { return }
        let body = (try? JSONSerialization.data(withJSONObject: object ?? ["ok": false, "error": code])) ?? Data()
        let reason = code == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(head.utf8); response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
}

import AppKit
import CryptoKit
import Foundation

/// Passive, authenticated metadata from the existing Desktop Host. Never reads its chat
/// records, starts a model, changes the profile or sends credentials outside loopback.
final class AtlasActivity: NSObject, URLSessionTaskDelegate {
    struct Work: Equatable {
        let sessionID: String
        let promptAt: Int64
    }
    private struct Metadata: Decodable { let lastPromptAt: Int64? }
    private struct Subagent: Decodable { let mode: String? }
    private struct Values: Decodable {
        let sessionListMetadata: Metadata?
        let subagent: Subagent?
    }
    private struct Projections: Decodable { let values: Values? }
    private struct Row: Decodable {
        let sessionId: String
        let cwd: String?
        let running: Bool?
        let agentAvailable: Bool?
        let projections: Projections?
        var work: Work { Work(sessionID: sessionId, promptAt: projections?.values?.sessionListMetadata?.lastPromptAt ?? 0) }
    }
    private struct Catalog: Decodable { let items: [Row] }
    private struct State: Decodable { let running: Bool; let pendingInput: [String] }
    private struct Wire<T: Decodable>: Decodable {
        struct Result: Decodable { let ok: Bool; let value: T? }
        let result: Result
    }
    private enum ReadError: Error { case unavailable }
    private static let bundleID = "com.deepseek.dsh"
    private let workspace: String
    private let secretURL: URL
    private let worker = DispatchQueue(label: "atlas.live.activity", qos: .utility)
    private lazy var http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var port: Int?
    private var observedPID: pid_t?
    private var catalog: [Row] = []
    private var catalogAt = Date.distantPast
    private var rediscoverAfter = Date.distantPast
    private var reading = false

    init(home: String = NSHomeDirectory()) {
        let env = ProcessInfo.processInfo.environment
        // DSH is entirely opt-in for a public download.
        workspace = env["VERA_ATLAS_DSH_WORKSPACE"] ?? ""
        secretURL = URL(fileURLWithPath: env["VERA_ATLAS_DSH_SECRET_FILE"] ?? "/dev/null")
    }

    // On main; serialise polls rather than stacking network requests when Desktop is busy.
    func poll(_ completion: @escaping (Work?) -> Void) {
        guard !workspace.isEmpty, secretURL.path != "/dev/null" else {
            completion(nil)
            return
        }
        guard !reading else { return }
        reading = true
        let desktopPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
        Task {
            let current = await read(desktopPID: desktopPID)
            await MainActor.run { self.reading = false; completion(current) }
        }
    }

    private func read(desktopPID: pid_t?) async -> Work? {
        if observedPID != desktopPID {
            observedPID = desktopPID
            port = nil; catalog = []; catalogAt = .distantPast; rediscoverAfter = .distantPast
        }
        guard let desktopPID else { return nil }
        if port == nil {
            guard Date() >= rediscoverAfter else { return nil }
            rediscoverAfter = Date().addingTimeInterval(4)
            port = await withCheckedContinuation { c in worker.async { c.resume(returning: Self.loopbackPort(pid: desktopPID)) } }
        }
        guard let port else { return nil }
        do {
            if Date().timeIntervalSince(catalogAt) >= 2.4 {
                let new: Catalog = try await rpc("session/list", args: ["_request": [:]], port: port)
                // Live DSH workers are genuine runtime sessions too. The
                // previous root-only filter silently discarded ALL active
                // subagents (and their UUID session IDs), leaving Atlas idle
                // while a worker model was actually running.
                catalog = new.items.filter {
                    $0.cwd == workspace && $0.agentAvailable == true
                }.sorted {
                    if ($0.running == true) != ($1.running == true) {
                        return $0.running == true
                    }
                    return $0.work.promptAt > $1.work.promptAt
                }
                catalogAt = Date()
            }
            // The latest attached conversations are sampled between catalogue updates. When a
            // turn closes or waits for the user's input, the cheaper state call sees it promptly.
            for row in catalog.enumerated() where row.offset < 3 || row.element.running == true {
                let state: State = try await rpc("session/state", args: ["request": ["sessionId": row.element.sessionId]], port: port)
                if state.running && state.pendingInput.isEmpty {
                    // If a newer prompt began between lists, don't apply a trace to the old epoch.
                    // A new list will immediately resolve the exact prompt time before adding focus.
                    return row.element.running == true ? row.element.work : Work(sessionID: row.element.sessionId, promptAt: 0)
                }
            }
            return nil
        } catch {
            self.port = nil; catalog = []; catalogAt = .distantPast
            return nil
        }
    }

    private static func command(_ path: String, _ args: [String]) -> String? {
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private static func loopbackPort(pid: pid_t) -> Int? {
        // Electron launches its Host as a direct child running the same executable;
        // the GUI process itself may have no listener. Do not scan unrelated listeners.
        guard let processes = command("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return nil }
        let entries = processes.split(separator: "\n").compactMap { row -> (pid_t, pid_t, Substring)? in
            let columns = row.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard columns.count == 3, let own = pid_t(columns[0]), let parent = pid_t(columns[1]) else { return nil }
            return (own, parent, columns[2])
        }
        guard let exe = entries.first(where: { $0.0 == pid })?.2 else { return nil }
        let candidates = [pid] + entries.filter { $0.1 == pid && $0.2 == exe }.map { $0.0 }
        guard candidates.count <= 12,
              let names = command("/usr/sbin/lsof", ["-nP", "-a", "-p", candidates.map(String.init).joined(separator: ","),
                                                     "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return nil }
        let prefix = "n127.0.0.1:"
        let ports = Set(names.split(separator: "\n").filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) })
        guard ports.count == 1, let port = ports.first, (1...65535).contains(port) else { return nil }
        return port
    }

    private static func urlBase64<D: DataProtocol>(_ bytes: D) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func cookie(for authority: String) throws -> String {
        let raw = try String(contentsOf: secretURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count == 43 else { throw ReadError.unavailable }
        let encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let secret = Data(base64Encoded: encoded), secret.count == 32 else { throw ReadError.unavailable }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let wire = try JSONSerialization.data(withJSONObject: ["version": 1, "authority": authority,
                                                               "issuedAt": ts, "expiresAt": ts + 300_000])
        let body = Self.urlBase64(wire)
        let sig = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))
        let host = Self.urlBase64(Data(SHA256.hash(data: Data(authority.utf8))))
        return "dsh-auth-\(host)=v1.\(body).\(Self.urlBase64(Data(sig)))"
    }

    private func rpc<T: Decodable>(_ method: String, args: [String: Any], port: Int) async throws -> T {
        let authority = "127.0.0.1:\(port)"
        var request = URLRequest(url: URL(string: "http://\(authority)/api/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try cookie(for: authority), forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "client-request", "rpcId": UUID().uuidString,
                                                                        "method": method, "payload": ["args": args]])
        let (data, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 6_000_000,
              let wire = try? JSONDecoder().decode(Wire<T>.self, from: data), wire.result.ok,
              let value = wire.result.value else { throw ReadError.unavailable }
        return value
    }

    // Never follow a redirect with an authenticated request, even another loopback route.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

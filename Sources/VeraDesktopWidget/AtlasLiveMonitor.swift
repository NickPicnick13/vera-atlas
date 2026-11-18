import AppKit
import CryptoKit
import WebKit

/// Joins two independent facts: the Desktop turn state and an attributed lookup.
/// The window gets only the boolean/epoch and the already-sanitized graph delta.
final class AtlasLiveMonitor {
    private let atlas: AtlasLiveData
    private let source = AtlasActivity()
    private weak var view: WKWebView?
    private var timer: Timer?
    private var deliveredWork: AtlasActivity.Work?
    private var deliveredFrame = false
    private var epoch = 0
    private var firstObservedAt: Int64 = 0
    private var closedEpochs: [String: Int64] = [:]
    private var traceRevision: String?
    private var accessRevision: String?
    private var accessTraceRevision: String?
    private var accessCursor: String?
    private var queuedMemoryPulses = 0
    private var memoryAccessJavaScriptInFlight = false
    private var pendingAccessTraces: [String: Date] = [:]
    private var pendingAccessDeltas: [String: String] = [:]
    private var workTraceStamp: String?
    private var previousReplayStamp: String?
    private var page = 0
    private let deliveryStartMS = Int64(Date().timeIntervalSince1970 * 1000)
    private var deliveryIDs: [String] = []
    private let deliveryURL: URL

    // Acknowledges a JavaScript merge, not physical pixel visibility.
    private func acknowledgeAtlasDelivery(_ keys: [String]) {
        for key in keys {
            let id = key.hasSuffix("-route") ? String(key.dropLast(6)) : key
            guard id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else { continue }
            if !deliveryIDs.contains(id) { deliveryIDs.append(id) }
        }
        if deliveryIDs.count > 512 { deliveryIDs = Array(deliveryIDs.suffix(512)) }
        let payload: [String: Any] = [
            "protocol": 1, "kind": "javascript_accepted",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "started_ms": deliveryStartMS,
            "at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "ids": deliveryIDs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            try FileManager.default.createDirectory(at: deliveryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: nil)
            try data.write(to: deliveryURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deliveryURL.path)
        } catch { /* Render remains independent from receipt persistence. */ }
    }


    init(atlas: AtlasLiveData, receiptSuffix: String = "") {
        self.atlas = atlas
        let userPath = ProcessInfo.processInfo.environment["VERA_ATLAS_DELIVERY_ACK_PATH"]
            ?? NSHomeDirectory() + "/Library/Application Support/VeraAtlas/atlas-render-ack.json"
        let base = URL(fileURLWithPath: userPath)
        self.deliveryURL = receiptSuffix.isEmpty ? base
            : URL(fileURLWithPath: base.deletingPathExtension().path + receiptSuffix + ".json")
        accessRevision = atlas.accessRevision
        accessTraceRevision = atlas.traceRevision
        accessCursor = atlas.latestAccessEventID()
    }

    func start() {
        guard timer == nil else { return }
        acknowledgeAtlasDelivery([])
        let timer = Timer(timeInterval: 0.61, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func attach(_ view: WKWebView, replayStamp: String?) {
        self.view = view
        previousReplayStamp = replayStamp
        deliveredWork = nil
        deliveredFrame = false
        traceRevision = nil
        workTraceStamp = nil
        page += 1
        tick()
    }

    func detach() { view = nil; page += 1; memoryAccessJavaScriptInFlight = false }
    func stop() {
        detach()
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard view != nil else { return }
        pollMemoryAccess()
        let revision = page
        source.poll { [weak self] work in
            guard let self, self.page == revision else { return }
            self.send(work)
        }
    }

    private func pollMemoryAccess() {
        guard let view, view.url?.isFileURL == true else { return }
        let eventRevision = atlas.accessRevision
        var newEvents: [AtlasMemoryAccessEvent] = []
        if eventRevision != accessRevision {
            newEvents = atlas.accessEvents(after: accessCursor)
            accessRevision = eventRevision
            if let latest = newEvents.last { accessCursor = latest.id }
            queuedMemoryPulses = min(8, queuedMemoryPulses + newEvents.count)
            for event in newEvents {
                if event.operation == "flash" { pendingAccessTraces[event.id] = Date() }
                if event.operation != "flash",
                   let delta = atlas.primaryRouteDeltaJSON(event.operation, skillID: event.skillID,
                                                           documentID: event.documentID,
                                                           toolID: event.toolID,
                                                           outcome: event.outcome,
                                                           projectID: event.projectID,
                                                           origin: event.origin,
                                                           actorID: event.actorID,
                                                           modelID: event.modelID,
                                                           role: event.role,
                                                           stage: event.stage,
                                                           processID: event.processID,
                                                           taskID: event.taskID) {
                    pendingAccessDeltas[event.id + "-route"] = delta
                }
            }
        }

        let now = Date()
        pendingAccessTraces = pendingAccessTraces.filter { now.timeIntervalSince($0.value) <= 45 }
        let traceDiskRevision = atlas.traceRevision
        if traceDiskRevision != accessTraceRevision || !newEvents.isEmpty {
            for accessID in pendingAccessTraces.keys.sorted() {
                guard let found = atlas.trace(forAccessID: accessID),
                      let delta = atlas.deltaJSON(trace: found, live: true, memoryAccess: true, operation: "flash") else { continue }
                pendingAccessDeltas[accessID] = delta
                pendingAccessTraces.removeValue(forKey: accessID)
            }
            accessTraceRevision = traceDiskRevision
        }
        guard !memoryAccessJavaScriptInFlight else { return }
        let pulseCount = min(4, queuedMemoryPulses)
        // atlas.js accepts at most 128 deltas per batch. Keep the rest pending
        // instead of dropping a whole observed burst.
        let readyDeltas = Array(pendingAccessDeltas.sorted { $0.key < $1.key }.prefix(128))
        guard pulseCount > 0 || !readyDeltas.isEmpty else { return }

        memoryAccessJavaScriptInFlight = true
        let revision = page
        let deltaIDs = readyDeltas.map { $0.key }
        let deltas = readyDeltas.map { $0.value }
        view.callAsyncJavaScript("""
            if ((pulseCount > 0 && !window.__atlasMemoryAccess) ||
                (deltas.length > 0 && !window.__mergeAtlasTrace)) return false;
            for (let i = 0; i < pulseCount; i++) window.__atlasMemoryAccess();
            if (deltas.length) {
                const parsed = deltas.map(JSON.parse);
                if (window.__mergeAtlasBatch) {
                    if (!window.__mergeAtlasBatch(parsed)) return false;
                } else for (const delta of parsed) window.__mergeAtlasTrace(delta);
            }
            return true;
            """, arguments: ["pulseCount": pulseCount, "deltas": deltas], in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                self.memoryAccessJavaScriptInFlight = false
                guard self.page == revision else { return }
                if case .success(let replied) = result, replied as? Bool == true {
                    if pulseCount > 0 {
                        self.queuedMemoryPulses = max(0, self.queuedMemoryPulses - pulseCount)
                        let receipt = "atlas-memory-access-painted pid=" + String(ProcessInfo.processInfo.processIdentifier) + " pulses=" + String(pulseCount) + "\n"
                        FileHandle.standardError.write(Data(receipt.utf8))
                    }
                    for id in deltaIDs { self.pendingAccessDeltas.removeValue(forKey: id) }
                    if !deltaIDs.isEmpty { self.acknowledgeAtlasDelivery(deltaIDs) }
                }
            }
    }

    private func send(_ work: AtlasActivity.Work?) {
        guard let view, view.url?.isFileURL == true else { return }
        let turnChanged = !deliveredFrame || work != deliveredWork
        if turnChanged {
            epoch += 1
            workTraceStamp = nil
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if work == nil, let previous = deliveredWork {
                closedEpochs[previous.sessionID] = now
            }
            if let work {
                // A Flash insertion can finish before the first poll. Accept it from this
                // prompt onward, but never resurrect an older edge after observed idle.
                firstObservedAt = closedEpochs[work.sessionID] ?? 0
            }
        }
        let diskRevision = atlas.traceRevision
        let newTrace = diskRevision != traceRevision
        var deltas: [String] = []
        if newTrace, let found = atlas.lastReplayTrace(), let ts = found["timestamp"] as? String,
           ts != previousReplayStamp, let delta = atlas.deltaJSON(trace: found) {
            previousReplayStamp = ts
            deltas.append(delta)
        }
        if (turnChanged || newTrace), let work, let found = atlas.lastWorkTrace(for: work, observedAfter: firstObservedAt),
           let ts = found["timestamp"] as? String, ts != workTraceStamp, let delta = atlas.deltaJSON(trace: found, live: true, memoryAccess: true) {
            workTraceStamp = ts
            deltas.append(delta)
        }
        traceRevision = diskRevision
        guard turnChanged || !deltas.isEmpty else { return }
        let revision = page
        deliveredWork = work
        deliveredFrame = true
        // The actor is derived ONLY from the authenticated native DSH
        // session ID. Its opaque identity matches the passive log watcher.
        let actorID: String? = work.map { current in
            let digest = SHA256.hash(data: Data(("dsh-session:" + current.sessionID).utf8))
            return "h-" + digest.prefix(12).map { String(format:"%02x", $0) }.joined()
        }
        view.callAsyncJavaScript("""
            if (!window.__setAtlasActivity || !window.__mergeAtlasTrace) return false;
            if (turnChanged) window.__setAtlasActivity({running, epoch, actorID});
            if (deltas.length) {
                const parsed = deltas.map(JSON.parse);
                if (window.__mergeAtlasBatch) window.__mergeAtlasBatch(parsed);
                else for (const delta of parsed) window.__mergeAtlasTrace(delta);
            }
            return true;
            """, arguments: ["turnChanged": turnChanged, "running": work != nil, "epoch": epoch,
                                    "actorID": actorID as Any? ?? NSNull(), "deltas": deltas], in: nil, in: .page) { [weak self] result in
                guard let self, self.page == revision else { return }
                if case .success(let replied) = result, replied as? Bool == true { return }
                self.deliveredFrame = false
                self.previousReplayStamp = nil
                self.traceRevision = nil
            }
    }
}

import AppKit
import WebKit
import CoreGraphics

/// Full-quality independent WebGL renderer on the second display.
final class AtlasTwinView: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    struct Settings {
        let idleLines: Bool
        let continuousWorkLines: Bool
        let comets: Bool
        let adaptiveShape: Bool
        let motionSpeed: Double
    }
    private let atlas: AtlasLiveData
    private lazy var liveMonitor = AtlasLiveMonitor(atlas: atlas, receiptSuffix: "-twin")
    private(set) var window: AtlasWindow?
    private(set) var view: WKWebView?
    private var activeScreenID: UInt32 = 0
    private var revision = 0
    private var settings = Settings(idleLines: false, continuousWorkLines: false,
                                    comets: false, adaptiveShape: true, motionSpeed: 1)
    private var ready = false
    private var lastFrame = NSRect.zero

    var isRunning: Bool { window?.isVisible == true && ready }
    var runningScreenID: UInt32 { activeScreenID }

    init(atlas: AtlasLiveData) {
        self.atlas = atlas
        super.init()
    }

    private static func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func desiredFrame(_ screen: NSScreen, fullscreen: Bool, normalSize: NSSize) -> NSRect {
        if fullscreen { return screen.visibleFrame }
        let f = screen.visibleFrame
        let w = min(max(normalSize.width, 320), min(900, f.width))
        let h = min(max(normalSize.height, 320), min(900, f.height))
        return NSRect(x: f.maxX-w-24, y: f.minY+24, width: w, height: h)
    }

    func show(on screen: NSScreen, fullscreen: Bool, normalSize: NSSize, settings: Settings) {
        self.settings = settings
        let frame = desiredFrame(screen, fullscreen: fullscreen, normalSize: normalSize)
        activeScreenID = Self.screenID(screen)
        if window == nil {
            let panel = AtlasWindow(graphRect: frame)
            panel.isReleasedWhenClosed = false
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "widget")
            let renderer = AtlasWebView(frame: NSRect(origin: .zero, size: frame.size),
                                        configuration: config)
            renderer.navigationDelegate = self
            renderer.setValue(false, forKey: "drawsBackground")
            panel.contentView = renderer
            window = panel
            view = renderer
            liveMonitor.start()
            if let resources = Bundle.main.resourceURL,
               let url = URL(string: resources.appendingPathComponent("proto.html").absoluteString + "#embed") {
                renderer.loadFileURL(url, allowingReadAccessTo: resources)
            }
        } else if let panel = window, !NSEqualRects(panel.frame, frame) {
            panel.setFrame(frame, display: true, animate: false)
        }
        window?.orderFrontRegardless()
        applySettings()
        if lastFrame != frame {
            let line = "atlas-twin-window pid=\(ProcessInfo.processInfo.processIdentifier) display=\(activeScreenID) frame=\(Int(frame.width))x\(Int(frame.height)) second_webview=1\n"
            FileHandle.standardError.write(Data(line.utf8))
            lastFrame = frame
        }
    }

    func applySettings() {
        guard ready, let view else { return }
        view.evaluateJavaScript("window.__widgetState?.('pinned')")
        view.evaluateJavaScript("window.__atlasSetIdleLines?.(\(settings.idleLines))")
        view.evaluateJavaScript("window.__atlasSetContinuousWorkLines?.(\(settings.continuousWorkLines))")
        view.evaluateJavaScript("window.__atlasSetComets?.(\(settings.comets))")
        view.evaluateJavaScript("window.__atlasSetAdaptiveShape?.(\(settings.adaptiveShape))")
        view.evaluateJavaScript("window.__atlasSetMotionSpeed?.(\(settings.motionSpeed))")
    }

    func stop() {
        revision += 1
        ready = false
        liveMonitor.stop()
        view?.navigationDelegate = nil
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "widget")
        view?.stopLoading()
        window?.orderOut(nil)
        window?.close()
        view = nil
        window = nil
        activeScreenID = 0
        lastFrame = .zero
    }

    func webView(_ rendered: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        revision += 1
        ready = false
        liveMonitor.detach()
    }

    func webView(_ rendered: WKWebView, didFinish navigation: WKNavigation!) {
        guard rendered === view, let initial = atlas.payload(trace: atlas.lastReplayTrace()) else { return }
        let generation = revision
        rendered.callAsyncJavaScript(
            """
            if (!window.__setAtlasData || !window.__atlasSetComets) return false;
            window.__atlasSetComets(cometsOn);
            window.__setAtlasData(JSON.parse(packet));
            return true;
            """, arguments: ["packet": initial, "cometsOn": settings.comets],
            in: nil, in: .page) { [weak self, weak rendered] result in
                guard let self, let rendered, generation == self.revision,
                      self.view === rendered else { return }
                if case .success(let succeeded) = result, succeeded as? Bool == true {
                    self.ready = true
                    self.applySettings()
                    let stamp = self.atlas.lastReplayTrace()?["timestamp"] as? String
                    self.liveMonitor.attach(rendered, replayStamp: stamp)
                    for delay in [3.0, 7.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rendered] in
                            guard let self, let rendered, self.view === rendered else { return }
                            rendered.evaluateJavaScript("window.__atlasMotionStatus?.()") { value, error in
                                let line = "atlas-motion-check role=twin pid=\(ProcessInfo.processInfo.processIdentifier) delay=\(delay) state=\(String(describing: value)) error=\(String(describing: error))\n"
                                FileHandle.standardError.write(Data(line.utf8))
                            }
                        }
                    }
                    rendered.evaluateJavaScript("""
                    (() => {
                        const surface = document.querySelector('canvas');
                        const report = window.__atlasViewStatus?.() || window.__atlasInspectable?.();
                        return {width: innerWidth, height: innerHeight,
                                canvas: !!surface, details: report || null};
                    })()
                    """) { result, _ in
                        let line = "atlas-twin-ready pid=\(ProcessInfo.processInfo.processIdentifier) display=\(self.activeScreenID) details=\(String(describing: result))\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                } else {
                    FileHandle.standardError.write(Data("atlas-twin-initial-graph-failed\n".utf8))
                }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "widget", message.webView === view else { return }
        if let fields = message.body as? [String: Any],
           fields["action"] as? String == "sphereReady" {
            let backend = fields["backend"] as? String ?? "unknown"
            let nodes = (fields["nodes"] as? NSNumber)?.intValue ?? -1
            let edges = (fields["graphEdges"] as? NSNumber)?.intValue ?? -1
            let comets = fields["cometsEnabled"] as? Bool ?? false
            let signals = (fields["cometSignals"] as? NSNumber)?.intValue ?? 0
            let line = "atlas-twin-topology pid=\(ProcessInfo.processInfo.processIdentifier) display=\(activeScreenID) backend=\(backend) nodes=\(nodes) edges=\(edges) comets=\(comets) signals=\(signals)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if let fields = message.body as? [String: Any],
           fields["action"] as? String == "atlasWorkPainted",
           fields["running"] as? Bool == true {
            let count = (fields["selectedLinks"] as? NSNumber)?.intValue ?? 0
            let line = "atlas-twin-work-painted pid=\(ProcessInfo.processInfo.processIdentifier) links=\(count)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

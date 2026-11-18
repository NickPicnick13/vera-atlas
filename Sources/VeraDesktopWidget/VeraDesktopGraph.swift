// Atlas: one native window, with its full content rectangle owned by WKWebView.
// The local memory trace is read-only; no query, source path or source text goes to WebKit.
import AppKit
import WebKit
import CoreGraphics

private let panelSide: CGFloat = 428

enum PanelState { case menubar, panel, pinned }

@main
enum VeraDesktopGraph {
    static func main() {
        // Local verification; do not create an NSApplication, window, or singleton lock.
        let exportBase = CommandLine.arguments.contains("--export-atlas-base")
        if exportBase || CommandLine.arguments.contains("--export-atlas-payload") {
            let data = AtlasLiveData()
            guard let json = data.payload(trace: exportBase ? nil : data.lastTrace()) else { exit(2) }
            print(json)
            return
        }
        // single-instance: второй экземпляр тихо выходит
        let lockPath = "/tmp/vera-atlas-community.lock"
        if let old = try? String(contentsOfFile: lockPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(old), pid > 0, kill(pid, 0) == 0 {
            exit(0)
        }
        try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: lockPath, atomically: true, encoding: .utf8)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // без иконки в Dock, не крадём фокус
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSWindow?
    private var webView: WKWebView?
    private var keyMonitor: Any?
    private var state: PanelState = .menubar
    private static let pinnedDefaultsKey = "communityAtlasWindowPinned"
    private var pinned = UserDefaults.standard.object(forKey: pinnedDefaultsKey) as? Bool ?? true
    private var initiallyPlaced = false
    private var ordinaryFrameBeforeScreenFill: NSRect?
    private var desktopBackdrop = false
    private static let idleLinesDefaultsKey = "communityAtlasShowIdleLines"
    private static let workLinesDefaultsKey = "communityAtlasContinuousWorkLines"
    private static let adaptiveShapeDefaultsKey = "communityAtlasAdaptiveShapeEnabled"
    private static let motionSpeedDefaultsKey = "communityAtlasMotionSpeed"
    private static let cometsDefaultsKey = "communityAtlasShowComets"
    private static let backdropDefaultsKey = "communityAtlasBackdropEnabled"
    private var showIdleLines = UserDefaults.standard.object(forKey: idleLinesDefaultsKey) as? Bool ?? false
    private var continuousWorkLines = UserDefaults.standard.object(forKey: workLinesDefaultsKey) as? Bool ?? false
    private var showComets = UserDefaults.standard.object(forKey: cometsDefaultsKey) as? Bool ?? false
    private var adaptiveShape = UserDefaults.standard.object(forKey: adaptiveShapeDefaultsKey) as? Bool ?? true
    private var motionSpeed = min(3, max(0, UserDefaults.standard.object(forKey: motionSpeedDefaultsKey) as? Double ?? 1.0))
    private weak var motionSpeedTitle: NSTextField?
    private var ordinaryFrameBeforeBackdrop: NSRect?
    private var pendingLayoutRead: DispatchWorkItem?
    private var lastLayoutRead: String?
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        makeStatusItem()
        startLiveTrace()   // graph + первый трейс → payloadJSON (до создания webview)
        makePanel()
        if UserDefaults.standard.bool(forKey: Self.backdropDefaultsKey) {
            toggleDesktopBackdrop()
        }
        installMonitors()
        // selftest: route a synthesized Escape through the same local monitor used by the live window.
        if CommandLine.arguments.contains("--selftest-escape") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = self.panel as? AtlasWindow else {
                    print("SELFTEST escape restore -> FAIL: no AtlasWindow")
                    NSApp.terminate(nil)
                    return
                }
                self.showDesktopWindow()
                let normal = window.contentRect(forFrameRect: window.frame).size
                self.toggleAtlasScreenFrame()
                let filled = window.frame
                let escape = String(UnicodeScalar(27)!)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: escape, charactersIgnoringModifiers: escape,
                                                isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(event, atStart: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let restored = window.contentRect(forFrameRect: window.frame).size
                    let passed = !window.fillsScreenFrame && filled.width > normal.width
                        && abs(restored.width - normal.width) < 1 && abs(restored.height - normal.height) < 1
                    print("SELFTEST Escape restores normal frame: filled=\(Int(filled.width))x\(Int(filled.height)) restored=\(Int(restored.width))x\(Int(restored.height)) -> \(passed ? "PASS" : "FAIL")")
                    NSApp.terminate(nil)
                }
            }
        }
        // обычный запуск (без demo/selftest): дашборд сразу на рабочем столе, иконка в меню-баре — только свернуть/развернуть
        if CommandLine.arguments.count <= 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.showDesktopWindow()
            }
        }
    }

    private func report(_ label: String, expect: PanelState) {
        let p = panel
        print("SELFTEST \(label): state=\(state) expect=\(expect) panelVisible=\(p?.isVisible ?? false) " +
              "level=\(p?.level.rawValue ?? -1) " +
              "size=\(p.map { "\($0.frame.width)x\($0.frame.height)" } ?? "-") " +
              (state == expect ? "PASS" : "FAIL"))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Красная кнопка окна = «Свернуть» в иконку меню-бара, приложение не умирает.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapsePanel()
        return false
    }

    // MARK: - Menu (Cmd+W закрывает панель, Cmd+Q — выход)

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let sub = NSMenu()
        let close = NSMenuItem(title: "Закрыть панель", action: #selector(closePanel), keyEquivalent: "w")
        close.target = self
        sub.addItem(close)
        let quit = NSMenuItem(title: "Завершить VeraAtlas", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        sub.addItem(quit)
        appItem.submenu = sub
        NSApp.mainMenu = main
    }

    // MARK: - Status item

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.graphGlyph(pinned: false)
        item.button?.toolTip = "Атлас памяти"
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// Graph-glyph 18×18, шаблонная. В pinned-состоянии добавляется точка-маркер (состояния различимы в меню-баре).
    private static func graphGlyph(pinned: Bool) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.set()
        let nodes: [CGPoint] = [
            CGPoint(x: 4.5, y: 4.5),
            CGPoint(x: 9.0, y: 13.5),
            CGPoint(x: 13.5, y: 5.5),
            CGPoint(x: 9.0, y: 9.0)
        ]
        let links = [(0, 3), (1, 3), (2, 3), (0, 1), (1, 2), (0, 2)]
        let path = NSBezierPath()
        path.lineWidth = 1.0
        path.lineCapStyle = .round
        for (a, b) in links {
            path.move(to: nodes[a])
            path.line(to: nodes[b])
        }
        path.stroke()
        for (i, p) in nodes.enumerated() {
            let r: CGFloat = i == 3 ? 2.6 : 2.1
            NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        if pinned {
            NSBezierPath(ovalIn: CGRect(x: 13.4, y: 13.4, width: 4.2, height: 4.2)).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = Self.graphGlyph(pinned: state == .pinned)
        statusItem?.button?.toolTip = switch state {
            case .menubar: "Атлас памяти"
            case .panel: "Атлас памяти — панель открыта (клик — свернуть)"
            case .pinned: "Атлас памяти — поверх окон (клик — свернуть)"
        }
    }

    /// Клик по иконке: окно видимо → спрятать; спрятано → показать на рабочем столе.
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            let menu = NSMenu()
            let pin = menu.addItem(withTitle: "Поверх окон", action: #selector(toggleAtlasPin), keyEquivalent: "")
            pin.target = self; pin.state = pinned ? .on : .off
            let screenFrame = menu.addItem(withTitle: (panel as? AtlasWindow)?.fillsScreenFrame == true ? "Вернуть размер" : "Развернуть на весь экран",
                                           action: #selector(toggleAtlasScreenFrame), keyEquivalent: "")
            screenFrame.target = self
            let backdrop = menu.addItem(withTitle: "Фоновый Атлас — под окнами",
                                        action: #selector(toggleDesktopBackdrop), keyEquivalent: "")
            backdrop.target = self
            backdrop.state = desktopBackdrop ? .on : .off
            let lines = menu.addItem(withTitle: "Фоновые линии — старый вид",
                                     action: #selector(toggleIdleLines), keyEquivalent: "")
            lines.target = self; lines.state = showIdleLines ? .on : .off
            let working = menu.addItem(withTitle: "Постоянные связи при работе модели",
                                        action: #selector(toggleContinuousWorkLines), keyEquivalent: "")
            working.target = self; working.state = continuousWorkLines ? .on : .off
            let comet = menu.addItem(withTitle: "Кометы поверх линий", action: #selector(toggleAtlasComets), keyEquivalent: "")
            comet.target = self; comet.state = showComets ? .on : .off
            let responsive = menu.addItem(withTitle: "Вписывать граф в экран",
                                          action: #selector(toggleAdaptiveShape), keyEquivalent: "")
            responsive.target = self; responsive.state = adaptiveShape ? .on : .off
            let motionItem = NSMenuItem()
            let motionControl = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 57))
            let speedLabel = NSTextField(labelWithString: motionSpeedText())
            speedLabel.frame = NSRect(x: 15, y: 32, width: 230, height: 20)
            speedLabel.font = .systemFont(ofSize: 12)
            speedLabel.textColor = .secondaryLabelColor
            motionControl.addSubview(speedLabel)
            motionSpeedTitle = speedLabel
            let speedSlider = NSSlider(frame: NSRect(x: 15, y: 5, width: 230, height: 26))
            speedSlider.minValue = 0
            speedSlider.maxValue = 3
            speedSlider.doubleValue = motionSpeed
            speedSlider.isContinuous = true
            speedSlider.target = self
            speedSlider.action = #selector(changeMotionSpeed(_:))
            motionControl.addSubview(speedSlider)
            motionItem.view = motionControl
            menu.addItem(motionItem)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Приблизить граф (+)", action: #selector(zoomAtlasIn), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Отдалить граф (−)", action: #selector(zoomAtlasOut), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Погрузиться во вселенную", action: #selector(expandAtlasUniverse), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Вернуть общий масштаб", action: #selector(resetAtlas), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Повторить последний выбор", action: #selector(replayAtlas), keyEquivalent: "").target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
            return
        }
        if let p = panel, p.isVisible && !p.isMiniaturized { collapsePanel() } else { showDesktopWindow() }
    }

    private func screen(for frame: NSRect, relativeTo window: NSWindow) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? window.screen ?? NSScreen.main
    }

    private func persistOrdinaryGeometry(_ window: AtlasWindow) {
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromPoint(window.frame.origin), forKey: Self.frameDefaultsKey)
        let size = window.contentRect(forFrameRect: window.frame).size
        defaults.set(NSStringFromSize(Self.clampedContent(size)), forKey: Self.sizeDefaultsKey)
    }

    private func normalFrameClampedToDisplay(_ frame: NSRect, relativeTo window: NSWindow) -> NSRect {
        guard let target = screen(for: frame, relativeTo: window) else { return frame }
        let visible = target.visibleFrame
        let maxSide = min(Self.maxContent.width, min(visible.width, visible.height))
        let side = min(max(max(frame.width, frame.height), Self.minContent.width), maxSide)
        let minX = visible.minX + 8, minY = visible.minY + 8
        let maxX = max(minX, visible.maxX - side - 8), maxY = max(minY, visible.maxY - side - 8)
        return NSRect(x: min(max(frame.minX, minX), maxX), y: min(max(frame.minY, minY), maxY),
                      width: side, height: side)
    }

    /// An ordinary borderless window covering only the usable desktop rectangle.
    /// It stays above the Finder desktop layer but below normal application windows.
    /// Pointer events reach this backdrop only in uncovered desktop areas.
    @objc private func toggleDesktopBackdrop() {
        guard let window = panel as? AtlasWindow else { return }
        if desktopBackdrop {
            desktopBackdrop = false
            window.ignoresMouseEvents = false
            let saved = ordinaryFrameBeforeBackdrop
            ordinaryFrameBeforeBackdrop = nil
            if let saved {
                window.setFrame(normalFrameClampedToDisplay(saved, relativeTo: window),
                                display: true, animate: false)
                persistOrdinaryGeometry(window)
            }
            applyState(pinned ? .pinned : .panel)
        } else {
            // Reuse the previously saved normal frame when leaving screen-fill.
            if window.fillsScreenFrame { toggleAtlasScreenFrame() }
            guard let target = screen(for: window.frame, relativeTo: window) else { return }
            ordinaryFrameBeforeBackdrop = window.frame
            persistOrdinaryGeometry(window)
            desktopBackdrop = true
            window.ignoresMouseEvents = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.setFrame(target.visibleFrame, display: true, animate: false)
        }
        if !window.isVisible { window.orderFrontRegardless() }
        UserDefaults.standard.set(desktopBackdrop, forKey: Self.backdropDefaultsKey)
        scheduleLayoutRead()
        let receipt = "atlas-desktop-backdrop pid=\(ProcessInfo.processInfo.processIdentifier) enabled=\(desktopBackdrop) level=\(window.level.rawValue) size=\(Int(window.frame.width))x\(Int(window.frame.height))\n"
        FileHandle.standardError.write(Data(receipt.utf8))
    }

    @objc private func toggleAtlasScreenFrame() {
        guard let window = panel as? AtlasWindow else { return }
        if desktopBackdrop { toggleDesktopBackdrop() }
        if window.fillsScreenFrame {
            let saved = ordinaryFrameBeforeScreenFill ?? window.frame
            window.fillsScreenFrame = false
            ordinaryFrameBeforeScreenFill = nil
            window.setFrame(normalFrameClampedToDisplay(saved, relativeTo: window), display: true, animate: false)
            persistOrdinaryGeometry(window)
        } else {
            guard let target = screen(for: window.frame, relativeTo: window) else { return }
            ordinaryFrameBeforeScreenFill = window.frame
            persistOrdinaryGeometry(window)
            window.fillsScreenFrame = true
            // A plain frame change creates no macOS fullscreen Space and does not make the window key.
            window.setFrame(target.frame, display: true, animate: false)
            // The menu bar is covered; keep Escape routed to this app's local key monitor.
            window.makeKey()
        }
        if !window.isVisible { window.orderFrontRegardless() }
        scheduleLayoutRead()
    }

    @objc private func toggleAtlasPin() {
        if panel?.isVisible == true { togglePin() }
        else { pinned.toggle(); UserDefaults.standard.set(pinned, forKey: Self.pinnedDefaultsKey) }
    }
    @objc private func toggleIdleLines() {
        showIdleLines.toggle()
        UserDefaults.standard.set(showIdleLines, forKey: Self.idleLinesDefaultsKey)
        webView?.evaluateJavaScript("window.__atlasSetIdleLines?.(\(showIdleLines ? "true" : "false"))")
        FileHandle.standardError.write(Data("atlas-idle-lines enabled=\(showIdleLines)\n".utf8))
    }
    private func motionSpeedText() -> String {
        if motionSpeed == 0 { return "Скорость движения: пауза" }
        return String(format: "Скорость движения: %.1f×", motionSpeed)
    }
    @objc private func changeMotionSpeed(_ sender: NSSlider) {
        motionSpeed = (min(3, max(0, sender.doubleValue)) * 10).rounded() / 10
        sender.doubleValue = motionSpeed
        motionSpeedTitle?.stringValue = motionSpeedText()
        UserDefaults.standard.set(motionSpeed, forKey: Self.motionSpeedDefaultsKey)
        webView?.evaluateJavaScript("window.__atlasSetMotionSpeed?.(\(motionSpeed))")
    }
    @objc private func toggleAdaptiveShape() {
        adaptiveShape.toggle()
        UserDefaults.standard.set(adaptiveShape, forKey: Self.adaptiveShapeDefaultsKey)
        webView?.evaluateJavaScript("window.__atlasSetAdaptiveShape?.(\(adaptiveShape ? "true" : "false"))")
        FileHandle.standardError.write(Data("atlas-adaptive-shape enabled=\(adaptiveShape)\n".utf8))
    }
    @objc private func toggleAtlasComets() {
        showComets.toggle()
        UserDefaults.standard.set(showComets, forKey: Self.cometsDefaultsKey)
        webView?.evaluateJavaScript("window.__atlasSetComets?.(\(showComets ? "true" : "false"))")
    }
    @objc private func toggleContinuousWorkLines() {
        continuousWorkLines.toggle()
        UserDefaults.standard.set(continuousWorkLines, forKey: Self.workLinesDefaultsKey)
        webView?.evaluateJavaScript("window.__atlasSetContinuousWorkLines?.(\(continuousWorkLines ? "true" : "false"))")
        FileHandle.standardError.write(Data("atlas-work-lines enabled=\(continuousWorkLines)\n".utf8))
    }
    @objc private func replayAtlas() { webView?.evaluateJavaScript("window.__atlasWindowCommand?.('replay')") }
    @objc private func resetAtlas() { webView?.evaluateJavaScript("window.__atlasWindowCommand?.('reset')") }
    @objc private func zoomAtlasIn() { webView?.evaluateJavaScript("window.__atlasWindowCommand?.('zoom-in')") }
    @objc private func zoomAtlasOut() { webView?.evaluateJavaScript("window.__atlasWindowCommand?.('zoom-out')") }
    @objc private func expandAtlasUniverse() { webView?.evaluateJavaScript("window.__atlasWindowCommand?.('universe')") }

    private static let frameDefaultsKey = "communityAtlasFrameOrigin"
    private static let legacyFrameDefaultsKey = "communityAtlasPanelFrame"

    /// Restore ordinary geometry on its last display. Screen-filling mode is intentionally transient.
    func showDesktopWindow() {
        guard let p = panel else { return }
        state = pinned ? .pinned : .panel
        applyState(state)
        if desktopBackdrop {
            windowDidReappearInBackdrop()
            return
        }
        if !initiallyPlaced {
            initiallyPlaced = true
            let main = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
            } ?? NSScreen.screens.first
            var f = p.frame
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: Self.frameDefaultsKey) {
                f.origin = NSPointFromString(saved)
            } else if let legacy = defaults.string(forKey: Self.legacyFrameDefaultsKey) {
                f.origin = legacy.hasPrefix("{{") ? NSRectFromString(legacy).origin : NSPointFromString(legacy)
            } else if let vis = main?.visibleFrame {
                f.origin = NSPoint(x: vis.maxX - f.width - 24, y: vis.minY + 24)
            }
            let center = NSPoint(x: f.midX, y: f.midY)
            let selected = NSScreen.screens.first { $0.frame.contains(center) } ?? main
            let vis = selected?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            f.origin.x = min(max(f.origin.x, vis.minX + 8), max(vis.minX + 8, vis.maxX - f.width - 8))
            f.origin.y = min(max(f.origin.y, vis.minY + 8), max(vis.minY + 8, vis.maxY - f.height - 8))
            p.setFrameOrigin(f.origin)
        }
        if p.isMiniaturized { p.deminiaturize(nil) }
        p.orderFrontRegardless()
        scheduleLayoutRead()
    }

    private func windowDidReappearInBackdrop() {
        guard let window = panel as? AtlasWindow else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = panel, notification.object as? NSWindow === p,
              (p as? AtlasWindow)?.fillsScreenFrame != true,
              !desktopBackdrop else { return }
        UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: Self.frameDefaultsKey)
    }

    // MARK: - Panel + WKWebView

    private static let sizeDefaultsKey = "communityAtlasContentSize"
    private static let sizeMigrationKey = "veraAtlasNormalSquareSizeV3"
    private static let minContent = NSSize(width: 320, height: 320)
    private static let maxContent = NSSize(width: 900, height: 900)

    private static func clampedContent(_ size: NSSize) -> NSSize {
        let w = size.width.isFinite ? size.width : panelSide
        let h = size.height.isFinite ? size.height : panelSide
        let side = min(max(max(w, h), minContent.width), maxContent.width)
        return NSSize(width: side, height: side)
    }

    private func savedContentSize() -> NSSize {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.sizeMigrationKey) {
            // Replace legacy rectangular/large sizes once; the separately saved origin remains intact.
            let compact = NSSize(width: panelSide, height: panelSide)
            defaults.set(NSStringFromSize(compact), forKey: Self.sizeDefaultsKey)
            defaults.set(true, forKey: Self.sizeMigrationKey)
            return compact
        }
        guard let saved = defaults.string(forKey: Self.sizeDefaultsKey) else {
            return NSSize(width: panelSide, height: panelSide)
        }
        return Self.clampedContent(NSSizeFromString(saved))
    }

    private func makePanel() {
        let rect = NSRect(origin: .zero, size: savedContentSize())
        let p = AtlasWindow(graphRect: rect)
        p.contentMinSize = Self.minContent
        p.contentMaxSize = Self.maxContent
        p.delegate = self

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "widget")
        let wv = AtlasWebView(frame: rect, configuration: cfg)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        // The transparent page owns the full borderless window; pinning does not affect size.
        p.contentView = wv
        panel = p
        webView = wv
        if let res = Bundle.main.resourceURL,
           let url = URL(string: res.appendingPathComponent("proto.html").absoluteString + "#embed") {
            wv.loadFileURL(url, allowingReadAccessTo: res)
        }
    }

    private func applyState(_ state: PanelState) {
        guard let p = panel else { return }
        let staysOnTop = state == .pinned
        p.level = desktopBackdrop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : (staysOnTop ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .normal)
        p.collectionBehavior = desktopBackdrop ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            : (staysOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [])
        p.ignoresMouseEvents = false
        p.hidesOnDeactivate = false
        updateStatusIcon()
        webView?.evaluateJavaScript("window.__widgetState && window.__widgetState('\(staysOnTop ? "pinned" : "panel")')")
    }

    func windowDidResize(_ notification: Notification) {
        guard let p = panel, notification.object as? NSWindow === p else { return }
        if (p as? AtlasWindow)?.fillsScreenFrame != true && !desktopBackdrop {
            let size = p.contentRect(forFrameRect: p.frame).size
            UserDefaults.standard.set(NSStringFromSize(Self.clampedContent(size)), forKey: Self.sizeDefaultsKey)
        }
        scheduleLayoutRead()
    }

    private func enforceSizeLimits() {
        guard let p = panel else { return }
        let size = p.contentRect(forFrameRect: p.frame).size
        let clamped = Self.clampedContent(size)
        if clamped != size { p.setContentSize(clamped) }
    }

    /// Позиционирование ТОЛЬКО на главном экране: под иконкой в меню-баре, кламп внутрь visibleFrame.
    private func openPanel() {
        guard let p = panel, let item = statusItem, let btn = item.button, let win = btn.window,
              let screen = NSScreen.main else { return }
        state = .panel
        applyState(.panel)
        let vis = screen.visibleFrame
        let btnScreen = win.convertToScreen(NSRect(origin: .zero, size: btn.frame.size))
        var x = btnScreen.midX - p.frame.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - p.frame.width - 8)
        var y = btnScreen.minY - 6 - p.frame.height
        if y < vis.minY + 8 { y = vis.minY + 8 }
        p.setFrame(NSRect(x: x, y: y, width: p.frame.width, height: p.frame.height), display: true)
        p.orderFrontRegardless()
        updateStatusIcon()
        webView?.evaluateJavaScript("window.__widgetState && window.__widgetState('panel')")
    }

    private func setPinned(_ value: Bool) {
        guard let p = panel else { return }
        pinned = value
        UserDefaults.standard.set(value, forKey: Self.pinnedDefaultsKey)
        state = value ? .pinned : .panel
        applyState(state)
        p.orderFrontRegardless()
    }

    private func pinPanel() { setPinned(true) }
    private func unpinPanel() { setPinned(false) }
    private func togglePin() { setPinned(!pinned) }

    /// Сдвиг окна на (dx, dy) — общий код drag и selftest.
    func movePanelBy(dx: CGFloat, dy: CGFloat) {
        guard let p = panel else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.origin.x + dx, y: p.frame.origin.y + dy))
    }

    /// «Свернуть» / повторный клик по иконке: панель уходит, остаётся только иконка в меню-баре.
    @objc func collapsePanel() {
        panel?.orderOut(nil)
        state = .menubar
        updateStatusIcon()
    }

    @objc func closePanel() { collapsePanel() }

    // MARK: - Local graph and authenticated read-only work state
    private lazy var atlas = AtlasLiveData()
    private lazy var liveMonitor = AtlasLiveMonitor(atlas: atlas)
    private var webReady = false
    private var pageRevision = 0
    private var paintedOnSince: TimeInterval?

    private func startLiveTrace() { liveMonitor.start() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let trace = atlas.lastReplayTrace()
        guard let initial = atlas.payload(trace: trace) else { return }
        let revision = pageRevision
        webView.callAsyncJavaScript("return !!window.__setAtlasData && (window.__setAtlasData(JSON.parse(packet)), true);",
                                    arguments: ["packet": initial], in: nil, in: .page) { [weak self] result in
            guard let self, revision == self.pageRevision else { return }
            if case .success(let value) = result, value as? Bool == true {
                self.webReady = true
                self.webView?.evaluateJavaScript("window.__widgetState?.('\(self.pinned ? "pinned" : "panel")')")
                self.webView?.evaluateJavaScript("window.__atlasSetIdleLines?.(\(self.showIdleLines ? "true" : "false"))")
                self.webView?.evaluateJavaScript("window.__atlasSetContinuousWorkLines?.(\(self.continuousWorkLines ? "true" : "false"))")
                self.webView?.evaluateJavaScript("window.__atlasSetComets?.(\(self.showComets ? "true" : "false"))")
                self.webView?.evaluateJavaScript("window.__atlasSetAdaptiveShape?.(\(self.adaptiveShape ? "true" : "false"))")
                self.webView?.evaluateJavaScript("window.__atlasSetMotionSpeed?.(\(self.motionSpeed))")
                self.scheduleLayoutRead()
                self.liveMonitor.attach(webView, replayStamp: trace?["timestamp"] as? String)
            } else {
                FileHandle.standardError.write(Data("atlas-initial-graph-not-applied\n".utf8))
            }
        }
    }

    private func scheduleLayoutRead() {
        pendingLayoutRead?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readLayout() }
        pendingLayoutRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.23, execute: work)
    }

    /// Native read-back from this window's WebKit page, without capturing the desktop.
    private func readLayout() {
        guard webReady, let panel, panel.isVisible, let view = webView, view.url?.isFileURL == true else { return }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        let viewport = view.bounds.size
        let nativeClear = (panel as? AtlasWindow)?.clearChrome == true
        view.evaluateJavaScript(AtlasWindow.readVisibleSurface) { [weak self] result, _ in
            guard let self, let layout = result as? [String: Any],
                  let width = (layout["width"] as? NSNumber)?.doubleValue,
                  let height = (layout["height"] as? NSNumber)?.doubleValue else { return }
            let frameFits = abs(content.width - viewport.width) <= 1 && abs(content.height - viewport.height) <= 1
                && abs(viewport.width - width) <= 1 && abs(viewport.height - height) <= 1
            let fits = frameFits && layout["fits"] as? Bool == true && layout["noOverflow"] as? Bool == true
            let hidden = layout["chromeHidden"] as? Bool == true, clear = layout["transparent"] as? Bool == true
            let line = "content=\(Int(content.width))x\(Int(content.height)) DOM=\(Int(width))x\(Int(height)) fits=\(fits) nativeClear=\(nativeClear) htmlClear=\(clear) chromeHidden=\(hidden)"
            if line != self.lastLayoutRead {
                self.lastLayoutRead = line
                FileHandle.standardError.write(Data("atlas-transparent-window pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n".utf8))
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        webReady = false
        paintedOnSince = nil
        liveMonitor.detach()
        pageRevision += 1
    }

    // MARK: - Web → native мост (кнопки в proto.html, embed-режим)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "widget", message.frameInfo.isMainFrame, webView?.url?.isFileURL == true else { return }
        let fields = message.body as? [String: Any]
        let action = (message.body as? String) ?? (fields?["action"] as? String) ?? ""
        switch action {
        case "atlasWorkPainted":
            guard let running = fields?["running"] as? Bool,
                  let links = (fields?["selectedLinks"] as? NSNumber)?.intValue, (0...100_000).contains(links) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if running && paintedOnSince == nil { paintedOnSince = now }
            let held = paintedOnSince.map { Int((now - $0) * 1000) } ?? 0
            if !running { paintedOnSince = nil }
            FileHandle.standardError.write(Data("atlas-work-painted pid=\(ProcessInfo.processInfo.processIdentifier) running=\(running) selectedLinks=\(links) heldMs=\(held)\n".utf8))
        case "graphHitArea":
            guard let window = panel as? AtlasWindow, let view = webView,
                  let x = (fields?["x"] as? NSNumber)?.doubleValue,
                  let y = (fields?["y"] as? NSNumber)?.doubleValue,
                  let radius = (fields?["r"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite, radius.isFinite, radius > 0,
                  radius <= Double(max(view.bounds.width, view.bounds.height)) * 2,
                  x >= -radius, x <= Double(view.bounds.width) + radius,
                  y >= -radius, y <= Double(view.bounds.height) + radius else { return }
            window.graphHitArea = NSRect(x: CGFloat(x - radius), y: CGFloat(y - radius),
                                         width: CGFloat(radius * 2), height: CGFloat(radius * 2))
        case "sphereReady":
            guard fields?["renderer"] as? String == "topology",
                  let nodes = (fields?["nodes"] as? NSNumber)?.intValue, (1...100_000).contains(nodes),
                  let links = (fields?["selectedLinks"] as? NSNumber)?.intValue, (0...100_000).contains(links) else { return }
            let graphEdges = (fields?["graphEdges"] as? NSNumber)?.intValue ?? 0
            let backend = fields?["backend"] as? String == "webgl" ? "webgl" : "canvas"
            let pid = ProcessInfo.processInfo.processIdentifier
            FileHandle.standardError.write(Data("atlas-topology-ready pid=\(pid) nodes=\(nodes) graphEdges=\(graphEdges) selectedLinks=\(links) backend=\(backend)\n".utf8))
        case "resizeWindow":
            guard let w = panel as? AtlasWindow, w.isVisible,
                  let dx = (fields?["dx"] as? NSNumber)?.doubleValue, let dy = (fields?["dy"] as? NSNumber)?.doubleValue,
                  dx.isFinite, dy.isFinite, abs(dx) <= 256, abs(dy) <= 256 else { return }
            w.resizeGraphWindow(dx: dx, dy: dy)
        case "pin": pinPanel()
        case "collapse": collapsePanel()
        case "togglePin": togglePin()
        default: break
        }
    }

    // MARK: - Cmd+W

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53,
               let self,
               let window = self.panel as? AtlasWindow,
               window.fillsScreenFrame {
                self.toggleAtlasScreenFrame()
                let size = window.contentRect(forFrameRect: window.frame).size
                let receipt = "atlas-screen-fill-escape pid=\(ProcessInfo.processInfo.processIdentifier) content=\(Int(size.width))x\(Int(size.height))\n"
                FileHandle.standardError.write(Data(receipt.utf8))
                return nil
            }
            if e.modifierFlags.contains(.command),
               e.charactersIgnoringModifiers?.lowercased() == "w" {
                self?.collapsePanel()
                return nil
            }
            return e
        }
    }

}

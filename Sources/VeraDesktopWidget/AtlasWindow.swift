import AppKit
import WebKit

/// Keep the first click working even when this window is not yet key.
final class AtlasWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A real Mac window without visible chrome. Command-drag moves the window;
/// WebKit owns graph rotation, panning, and zoom.
final class AtlasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // WebKit's projected sphere bounds, measured from the top-left of the content view.
    var graphHitArea: NSRect?
    var fillsScreenFrame = false
    private var drag: (point: NSPoint, origin: NSPoint)?

    init(graphRect rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Атлас памяти"
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    func cancelManipulation() {
        drag = nil
    }

    /// Hit bounds from the page use its top-left origin; AppKit's view origin is bottom-left.
    private func isInsideGraph(_ point: NSPoint) -> Bool {
        guard let hit = graphHitArea, hit.width > 0, hit.height > 0 else { return false }
        let topY = frame.height - point.y
        let rx = (point.x - hit.midX) / max(1, hit.width * 0.5)
        let ry = (topY - hit.midY) / max(1, hit.height * 0.5)
        return rx * rx + ry * ry <= 1
    }

    override func sendEvent(_ event: NSEvent) {
        if let activeDrag = drag {
            switch event.type {
            case .leftMouseDragged:
                let point = convertPoint(toScreen: event.locationInWindow)
                let fresh = NSPoint(x: activeDrag.origin.x + point.x - activeDrag.point.x,
                                    y: activeDrag.origin.y + point.y - activeDrag.point.y)
                let targetScreen = NSScreen.screens.first { $0.frame.contains(point) } ?? screen
                let origin = targetScreen.map { target in
                    let visible = target.visibleFrame
                    return NSPoint(x: min(max(fresh.x, visible.minX), max(visible.minX, visible.maxX - frame.width)),
                                   y: min(max(fresh.y, visible.minY), max(visible.minY, visible.maxY - frame.height)))
                } ?? fresh
                setFrameOrigin(origin)
                return
            case .leftMouseUp:
                drag = nil
                return
            default: break
            }
        }
        let modifiers = event.modifierFlags
        if !fillsScreenFrame, event.type == .leftMouseDown, modifiers.contains(.command),
           modifiers.intersection([.option, .shift, .control]).isEmpty,
           isInsideGraph(event.locationInWindow) {
            // Intercept before WKWebView's first-mouse check so the first ⌘-drag works.
            makeKey()
            drag = (convertPoint(toScreen: event.locationInWindow), frame.origin)
            return
        }
        if event.type == .leftMouseDown && !isKeyWindow {
            // Promote the clicked window before forwarding; otherwise AppKit may consume the first
            // Shift-mouseDown before WKWebView's pointer handler can establish its drag state.
            makeKey()
        }
        super.sendEvent(event)
    }

    func resizeGraphWindow(dx: CGFloat, dy: CGFloat) {
        guard !fillsScreenFrame else { return }
        let initial = frame
        let delta = abs(dx) >= abs(dy) ? dx : dy
        let visible = screen?.visibleFrame ?? initial.insetBy(dx: -contentMaxSize.width, dy: -contentMaxSize.height)
        let maximum = min(contentMaxSize.width, visible.maxX - initial.minX, initial.maxY - visible.minY)
        let side = max(contentMinSize.width, min(initial.width + delta, maximum))
        setFrame(NSRect(x: initial.minX, y: initial.maxY - side, width: side, height: side), display: true)
    }

    var clearChrome: Bool {
        !styleMask.contains(.titled) && !isOpaque && !hasShadow && backgroundColor.alphaComponent == 0
    }

    /// Read back the installed page without a desktop screenshot or exposing graph contents.
    static let readVisibleSurface = """
        (() => {
            const width = innerWidth, height = innerHeight;
            const boxes = ['main','.stage','#graph', '.atlas-volume'].map(s => document.querySelector(s)).filter(Boolean);
            const fits = boxes.length >= 3 && boxes.every(el => {
                const r=el.getBoundingClientRect();
                return Math.abs(r.left)<1 && Math.abs(r.top)<1 && Math.abs(r.right-width)<1 && Math.abs(r.bottom-height)<1;
            });
            const transparent = [document.documentElement,document.body,...boxes].every(el => {
                const css=getComputedStyle(el);
                return (css.backgroundColor==='rgba(0, 0, 0, 0)'||css.backgroundColor==='transparent') &&
                    css.backgroundImage==='none' && css.boxShadow==='none' && css.borderTopWidth==='0px';
            });
            const chromeHidden = Array.from(document.querySelectorAll('header,footer,button,#note,h1,[data-atlas-overlay]'))
                .every(el => el.getClientRects().length===0);
            return {width,height,fits,transparent,chromeHidden,
                    noOverflow:document.documentElement.scrollHeight<=height && document.documentElement.scrollWidth<=width};
        })()
        """
}

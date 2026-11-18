import AppKit
import CoreGraphics
import Foundation

// A fixed, local-only bridge to the existing AppKit menu handlers.
// No networking, AppleScript, artificial graph events or shell execution.
final class Receipt: NSObject {
    let requestID: String
    var received = false
    var payload: [String: Any] = [:]
    init(_ requestID: String) { self.requestID = requestID }
    @objc func didReceive(_ notification: Notification) {
        guard notification.userInfo?["request_id"] as? String == requestID else { return }
        payload = (notification.userInfo ?? [:]).reduce(into: [String: Any]()) { result, element in
            if let key = element.key as? String { result[key] = element.value }
        }
        received = true
    }
}
func fail(_ reason: String) -> Never {
    fputs("ATLAS_CONTROL_ERROR \(reason)\n", stderr)
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else { fail("usage: atlas_live_bridge BUNDLE OPTION VALUE") }
let bundle = args[0], option = args[1], raw = args[2]
guard bundle == "local.vera.desktop-widget" || bundle == "org.vera-atlas.community" else {
    fail("unrecognized bundle")
}
let validBools: Set<String> = ["comets", "idle-lines", "work-lines", "adaptive-shape", "dual", "backdrop", "pinned", "fullscreen"]
let number: NSNumber
if validBools.contains(option) {
    guard raw == "on" || raw == "off" else { fail("expected on or off") }
    number = NSNumber(value: raw == "on")
} else if ["zoom-in", "zoom-out", "universe", "reset-view", "fit-frame",
           "live-status", "presentation-small", "presentation-full"].contains(option) {
    guard raw == "go" else { fail("action must be go") }
    number = NSNumber(value: true)
} else if option == "speed" {
    guard let speed = Double(raw), speed.isFinite, speed >= 0, speed <= 3 else {
        fail("speed must be 0 through 3")
    }
    number = NSNumber(value: speed)
} else if option == "screen" {
    let displays = NSScreen.screens
    guard displays.count > 1 else { fail("a second display is not connected") }
    let mainID = CGMainDisplayID()
    let target: NSScreen?
    switch raw {
    case "main": target = displays.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID
    }
    case "other": target = displays.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != mainID
    }
    default: target = displays.first {
        $0.localizedName.localizedCaseInsensitiveContains(raw)
    }
    }
    guard let id = target?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        fail("display name not found")
    }
    number = id
} else {
    fail("unrecognized operation")
}
let requestID = UUID().uuidString
let events = DistributedNotificationCenter.default()
let listener = Receipt(requestID)
let ack = Notification.Name(bundle + ".live-control-ack")
events.addObserver(listener, selector: #selector(Receipt.didReceive(_:)),
                   name: ack, object: nil, suspensionBehavior: .deliverImmediately)
defer { events.removeObserver(listener) }
events.post(name: Notification.Name(bundle + ".live-control"),
            object: nil,
            userInfo: ["option": option, "value": number, "request_id": requestID])
let limit = Date().addingTimeInterval(3)
while !listener.received && Date() < limit {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
guard listener.received else { fail("no acknowledgement from the running Atlas; check its process/version") }
guard JSONSerialization.isValidJSONObject(listener.payload),
      let encoded = try? JSONSerialization.data(withJSONObject: listener.payload, options: [.sortedKeys]),
      let json = String(data: encoded, encoding: .utf8) else {
    fail("invalid app acknowledgement payload")
}
print(json)

import Foundation
import Network

enum Wire {
    static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

var checks = 0
func check(_ label: String, _ value: @autoclosure () -> Bool) {
    checks += 1
    if !value() { fatalError(label) }
}

let old = NWConnection()
let replacement = NWConnection()
let link = SessionLink()
link.connection = old
let transport = MacAudioRouteTransport(link: link)
let defaults = AudioRouteDefaults(inputUID: "mac.input", outputUID: "mac.output")
let selection = AudioRouteSelection(revision: UUID(), expected: defaults, outputUID: "usb.output")
var cancelled: [UUID] = []

check("old connection can be held", link.hold(old))
check("held route change accepted for old peer", transport.change(selection, on: old) { cancelled.append($0) })
transport.reset()
link.connection = replacement
_ = link.unhold(old)
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
check("peer move cancels the request ID", cancelled == [selection.requestID])
check("held change never reaches replacement", replacement.sent.isEmpty)
check("cancelled change never reaches old peer", old.sent.isEmpty)

link.connection = old
check("held fetch accepted for exact peer", link.hold(old) && transport.fetch(on: old))
link.connection = replacement
_ = link.unhold(old)
check("fetch never follows a peer move", replacement.sent.isEmpty && old.sent.isEmpty)
check("old peer fetch refused after move", !transport.fetch(on: old))

let active = AudioRouteSelection(revision: UUID(), expected: defaults, inputUID: "usb.input")
check("active change sent", transport.change(active, on: replacement) { cancelled.append($0) })
check("change sent only to chosen peer", replacement.sent.count == 1 && old.sent.isEmpty)
let bytes = replacement.sent[0]
let header = StreamMessage.parseHeader(Data(bytes.prefix(StreamMessage.headerLength)))!
check("wire kind is 209", header.kind == .changeAudioRoute)
let decoded = Wire.decode(AudioRouteSelection.self, from: Data(bytes.dropFirst(StreamMessage.headerLength)))
check("wire request ID and CAS token preserved", decoded == active)
transport.finish(active.requestID)
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
check("submitted change is not reported cancelled", cancelled == [selection.requestID])

let expired = AudioRouteSelection(revision: UUID(), expected: defaults, outputUID: "usb.output")
check("second hold entered", link.hold(replacement))
check("held change accepted", transport.change(expired, on: replacement) { cancelled.append($0) })
transport.finish(expired.requestID)
_ = link.unhold(replacement)
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
check("timeout cancellation removes held change", replacement.sent.count == 1 && cancelled.contains(expired.requestID))

print("\(checks) Mac audio transport checks passed")

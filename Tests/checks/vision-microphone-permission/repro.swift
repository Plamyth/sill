import Foundation
import StreamProtocol
final class Peer {}
let object = Peer()
let peer = ObjectIdentifier(object)
let generation = UUID()
let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop, geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
let capability = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())
let list = WindowList(macName: "Test Mac", windows: [], active: .desktop, inputGeneration: generation.uuidString, videoEpoch: epoch, microphone: capability)
var policy = IPadMicrophonePolicy()
_ = policy.setConnection(peer)
_ = policy.observe(list, from: peer)
let effects = policy.toggle()
let starts = effects.filter { if case .send(_, let control) = $0 { return control.operation == .start }; return false }.count
print("HOST_STARTS_BEFORE_PERMISSION \(starts)")
if starts != 0 { print("FAIL permission must precede host start: expected 0, actual \(starts)"); exit(1) }
print("PASS permission precedes host start")

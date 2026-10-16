import AVFoundation
import Foundation
import Network
import StreamProtocol

var checks = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}
func pump(_ until: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !until() && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
}
let peer = NWConnection(), client = StreamClient()
client.connection = peer; client.microphoneSetConnection(peer)
let generation = UUID().uuidString
let epoch = VideoEpoch(generation:generation,source:.desktop,geometry:.init(x:0,y:0,width:1,height:1),width:1,height:1)
var list = WindowList(macName:"Mac",windows:[],active:.desktop,inputGeneration:generation,videoEpoch:epoch)
client.microphoneObserve(list,from:peer); client.toggleVisionMicrophone()
check(peer.sent.isEmpty && permissionRequests.withLock { $0 == 0 }, "actual client capnil produces no permission or packet")
list.microphone = MicrophoneCapability(peer:UUID(),destination:UUID(),generation:UUID())
client.microphoneObserve(list,from:peer)
check(peer.sent.isEmpty && permissionRequests.withLock { $0 == 0 }, "actual client capability observation is inert")
client.toggleVisionMicrophone()
let start = Wire.decode(MicrophoneControl.self,from:Data(peer.sent.last!.dropFirst(StreamMessage.headerLength)))!
check(permissionRequests.withLock { $0 == 0 }, "actual client waits for matching host grant before permission")
let grant = UUID(), response = MicrophoneState(requestID:start.requestID,scope:start.scope,phase:.active,grantID:grant)
let body = Wire.encode(response)
let header = StreamMessage.parseHeader(StreamMessage(kind:.microphoneState,timestamp:0,isKeyframe:false,payload:body).serialized())!
_ = client.receiveMicrophone(header,body,from:peer)
pump { client.microphonePhase == .live }
check(client.microphonePhase == .live && permissionRequests.withLock { $0 == 1 }, "actual capture and shared graph commit open exact grant")
let graph = VisionAudioSharedHardware.graph
let format = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1)!
let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
buffer.frameLength = 4800
for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.25 }
let input = graph.input
input?.copyInput(buffer,AVAudioTime(sampleTime:0,atRate:48_000))
pump { peer.sent.contains { StreamMessage.parseHeader($0)?.kind == .microphoneFrame } }
let batches = peer.sent.filter { StreamMessage.parseHeader($0)?.kind == .microphoneFrame }
check(batches.count == 1, "actual100ms conversion reaches one scoped network batch")
var decoded: [MicrophoneFrame] = []
if let first = batches.first {
    var bytes = first
    while bytes.count >= StreamMessage.headerLength, let head = StreamMessage.parseHeader(bytes) {
        let count = StreamMessage.headerLength + head.payloadLength
        guard head.kind == .microphoneFrame, bytes.count >= count,
              let frame = MicrophoneFrame(encoded:Data(bytes[StreamMessage.headerLength..<count])) else { break }
        decoded.append(frame); bytes = Data(bytes.dropFirst(count))
    }
    check(bytes.isEmpty,"actual client batch framing fully decodes")
}
check(decoded.count == 5 && decoded.map(\.sequence) == [1,2,3,4,5], "actual converter to wire preserves all five ordered packets")
check(decoded.allSatisfy { $0.scope == start.scope && $0.grantID == grant && $0.frameCount == 960 }, "actual PCM packets retain exact Mac grant and source")
check(decoded.allSatisfy { frame in stride(from:0,to:frame.pcm.count,by:2).allSatisfy { frame.pcm[$0] == 0 && frame.pcm[$0+1] == 32 } }, "actual converter wirePCM preserves samples")
client.microphoneBackgrounded()
let before = peer.sent.count
input?.copyInput(buffer,AVAudioTime(sampleTime:4800,atRate:48_000))
RunLoop.main.run(until:Date().addingTimeInterval(0.03))
check(client.microphoneCapture == nil && client.microphonePhase == .unavailable && peer.sent.count == before,
      "actual background closes converter and frame transport against late input")
check(permissionRequests.withLock { $0 == 1 } && VisionAudioSharedHardware.shared.cleanupProblem == nil,
      "actual capture shutdown does not reauthorize or quarantine healthy hardware")
print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)

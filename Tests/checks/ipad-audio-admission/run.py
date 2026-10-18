"""Native locks/send/render callbacks with controlled engines and a held main queue."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(root/'Tests/checks'))
from swift_platform import select_platform
client = select_platform((root/'iOSClient/StreamClient.swift').read_text(), vision=False, ios=True)
start = client.index('        case .windowList:', client.index('private func handle(')) if 'private func handle(' in client else client.index('        case .windowList:', client.index('private func deliver('))
prefix = client[start:client.index('                // A remote session,', start)]
prefix = prefix.replace('        case .windowList:', '    func catalog(_ data: Data, from peer: NWConnection) {', 1)
new = (root/'iOSClient/IPadAudioAdmission.swift').exists()
fixture = '''import Foundation
import Network
import AVFoundation
import StreamProtocol
final class ClientProbe {
    var connection: NWConnection?
    var suspensions = 0
    let remoteAudioControl = IPadRemoteAudioController(send: { _,_ in }, stop: {}, play: { _,_ in }, changed: { _ in })
    func microphoneObserve(_ list: WindowList, from peer: NWConnection) {}
    func desiredAudioObserve(_ list: WindowList, from peer: NWConnection) {}
    func suspendDesiredAudio() { suspensions += 1; remoteAudioControl.backgrounded() }
'''
if new:
    fixture += '    let audioAdmission = IPadAudioAdmission()\n    var audioCatalogAdmission: IPadAudioAdmission.Ticket?\n'
    desired = (root/'iOSClient/StreamClient+DesiredAudio.swift').read_text()
    marker = '    func admitAudioCatalog('
    a=desired.index(marker); b=desired.index('\n    func ', a+len(marker))
    fixture += desired[a:b] + '\n'
    fixture += '''    func desiredAudioPermits(_ direction: IPadDesiredAudio.Direction) -> Bool {
        guard let connection else { return false }
        return audioCatalogAdmission != nil && audioAdmission.ticket(for: ObjectIdentifier(connection)) == audioCatalogAdmission
    }
'''
    audio = select_platform((root/'iOSClient/StreamClient+Audio.swift').read_text(), vision=False, ios=True)
    a = audio.index('    func receiveRemoteAudio('); b = audio.index('    func sendRemoteAudio(', a)
    fixture += audio[a:b]
    fixture += '''    var microphonePolicy = IPadMicrophonePolicy()
    var microphoneReceipt: MicrophoneReceipt?
    var grants = 0
    func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect]) {
        for effect in effects { if case .beginCapture = effect { grants += 1 } }
    }
    func reconcileDesiredAudio() {}
'''
    mic = select_platform((root/'iOSClient/StreamClient+Microphone.swift').read_text(), vision=False, ios=True)
    a = mic.index('    func receiveMicrophone('); b = mic.index('    func applyMicrophone(', a)
    fixture += mic[a:b]


fixture += prefix + '            }\n    }\n}\n'
(out/'ClientFixture.swift').write_text(fixture)
subprocess.run(['python3','-B',str(root/'Tests/checks/iPad-remote-audio/player-fixture.py'),str(root),str(out)],check=True)
p=out/'PlaybackFixture.swift'
logger=(root/'iOSClient/IPadMicrophoneCapture.swift').read_text().split('/// Native capture only.')[0]
a=logger.index('    static let shared ='); b=logger.index('    let fileURL:',a)
logger=logger[:a]+'    static let shared = IPadMicrophoneDiagnostics(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("diagnostics.json"))\n'+logger[b:]
(out/'Diagnostics.swift').write_text(logger)
standins=(root/'Tests/checks/iPad-remote-audio/player-standins.swift').read_text()
a=standins.index('final class FakeAudioSourceNode'); b=standins.index('final class IPadAudioSession')
render='''final class FakeAudioSourceNode {
    let callback: (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus
    init(format: AVAudioFormat, renderBlock: @escaping (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus) { callback = renderBlock }
    func render() -> [Float] {
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        defer { memory.deallocate() }
        memory.initialize(repeating: -1, count: 32)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 128, mData: memory))
        var silence = ObjCBool(false); var stamp = AudioTimeStamp()
        _ = callback(&silence, &stamp, 32, &list)
        return Array(UnsafeBufferPointer(start: memory, count: 32))
    }
}
final class FakeAudioEngine {
    static var failStart = false
    static var starts = 0
    var node: FakeAudioSourceNode!
    var stopped = false
    var isRunning = false
    let mainMixerNode = 0
    func stop() { stopped = true; isRunning = false }
    func attach(_ source: FakeAudioSourceNode) { node = source }
    func connect(_ source: FakeAudioSourceNode, to: Int, format: AVAudioFormat) {}
    func start() throws { Self.starts += 1; isRunning = true }
}
'''
s=p.read_text(); s=s.replace(standins[a:b],render);p.write_text(s)
flags=['-swift-version','5','-whole-module-optimization','-module-cache-path',str((out/'cache').resolve())]
protocol=sorted(map(str,(root/'Sources/StreamProtocol').glob('*.swift')))
def run(command):
    r=subprocess.run(command)
    if r.returncode: sys.exit(r.returncode)
run(['/usr/bin/xcrun','swiftc',*flags,'-emit-library','-emit-module','-module-name','StreamProtocol',*protocol,'-emit-module-path',str(out/'StreamProtocol.swiftmodule'),'-o',str(out/'libStreamProtocol.dylib')])
files=['IPadMicrophonePCM.swift','IPadMicrophoneFrameGate.swift','IPadRemoteAudioController.swift']
if new: files+=['IPadAudioAdmission.swift','IPadDesiredAudio.swift','IPadMicrophonePolicy.swift']
run(['/usr/bin/xcrun','swiftc',*flags,'-parse-as-library',*(['-D','ADMISSION'] if new else []),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),*[str(root/'iOSClient'/f) for f in files],str(out/'Diagnostics.swift'),str(out/'ClientFixture.swift'),str(out/'PlaybackFixture.swift'),str(Path(__file__).with_name('main.swift')),'-o',str(out/'check')])
run([str(out/'check'),str(out)])

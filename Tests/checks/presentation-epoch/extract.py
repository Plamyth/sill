import hashlib
import importlib.util
import sys
from pathlib import Path


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(root):
    root = Path(root).resolve()
    here = root / 'Tests/checks/presentation-epoch'
    sys.path.insert(0, str(root / 'Tests/checks'))
    platform = load(root / 'Tests/checks/swift_platform.py', 'epoch_platform')
    prior = load(root / 'Tests/checks/vision-input-controls/extract.py', 'epoch_prior')
    files, manifest = prior.fixture()
    block = prior.block
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    files['Client.swift'] = files['Client.swift'].replace('// EXTRACTED', '')
    native = (root / 'iOSClient/HEVCDisplayView.swift').read_text()
    declarations = [block(native, 'private enum NativeBinding:')]
    for marker in ['private var nativeLayer:', 'private var nativeBinding =', 'private var nativeLegacyPeer:',
                   'private var presentation =', 'private var retiring:', 'private var presentationObservers:',
                   'private var presentationForeground =', 'private var pendingNativePS:', 'private var pendingNativeIDR:']:
        declarations.append(next(line.strip() for line in native.splitlines() if line.strip().startswith(marker)))
    declarations += [block(native, 'private var displayLayer:')]
    methods = ['private func applyFormat(', 'private func enqueueSample(', 'func setPresentation(',
               'func setPresentationForeground(', 'func receiveParameters(', 'func receiveFrame(',
               'private func invalidateNativeMedia(', 'private func rebuildNativeLayer(', 'private func readPresentation(',
               'func clear()', 'func applyLegacy(', 'func enqueueLegacy(']
    body = '\n'.join(declarations + [platform.select_platform(block(native, marker), vision=True) for marker in methods])
    body = body.replace('private ', '')
    files['Display.swift'] = '''import Foundation
import StreamProtocol
final class EpochDisplay {
    var window: NSObject? = NSObject()
    var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let layer = CALayer()
    let presentationShield = CALayer()
    let cursorLayer = CALayer()
    var formatDescription: CMVideoFormatDescription?
    var waitingForKeyframe = true
    var lastParameterSets: Data?
    var pointerVideoSize = CGSize.zero
    var onVideoSize: ((CGSize) -> Void)?
    var onVideoSizeForPointer: ((CGSize) -> Void)?
    var onPresentation: ((VisionPresentation.Ticket?) -> Void)?
    func placeCursor() {}
''' + body + '\n}\n'
    server = (root / 'Sources/SillHost/StreamServer.swift').read_text()
    methods = ['func resetForNewStream()', 'func prepareVideo(', 'func commitVideo(', 'func broadcast(',
               'private func paceRemote(', 'private func remoteKeyframeDue(', 'private func send(_ raw:',
               'private func took(', 'func send(_ message: StreamMessage, to connection:']
    host = (here / 'Host.swift').read_text().replace('// CLIENT', block(server, 'private final class Client {').replace('private ', ''))
    host = host.replace('// METHODS', '\n'.join(block(server, marker).replace('private ', '') for marker in methods))
    files['Host.swift'] = host
    files['Host.swift'] += '\n' + block(server, 'final class SourcePublicationAdmission')
    coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
    geometry_methods = ['private enum GeometryRecovery {', 'private enum Held {', 'private func currentSourceRect(',
                        'private static func epochGeometry(', 'private func presentationInputRect(',
                        'private func deliver(', 'private func applyAdmittedInput(', 'private func releaseHeldInput()']
    input_start = coordinator.index('        case .input:', coordinator.index('private func handle(_ message:'))
    input_end = coordinator.index('        case .gesture:', input_start)
    input_body = coordinator[input_start:input_end]
    geometry_body = '\n'.join(block(coordinator, marker).replace('private ', '') for marker in geometry_methods)
    geometry_body += '\nfunc receive(_ message: StreamMessage, from connection: NWConnection) {\n switch message.kind {\n' + input_body + '\ndefault: break\n}\n}\n'
    files['Sources/SillHost/SourceInputFence.swift'] = (root / 'Sources/SillHost/SourceInputFence.swift').read_text()
    files['Geometry.swift'] = (here / 'Geometry.swift').read_text().replace('// METHODS', geometry_body)
    manifest['geometryMethods'] = hashlib.sha256(geometry_body.encode()).hexdigest()
    network = (root / 'Tests/checks/vision-input-controls/Network.swift').read_text()
    network = network.replace('public final class NWConnection {', '''public final class NWConnection {
    public enum State { case ready, cancelled }
    public var state = State.ready
    public var endpoint = "inert-peer"
''')
    network = network.replace('        lock.unlock()\n    }', '        lock.unlock()\n        if case .contentProcessed(let done) = completion { done(nil) }\n    }', 1)
    network = network.replace('    public func cancel() {}', '''    public var inbound = Data()
    private var readOffset = 0
    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: (Data?, String?, Bool, NWError?) -> Void) {
        guard readOffset < inbound.count else { completion(nil, nil, true, nil); return }
        let end = min(inbound.count, readOffset + maximumLength)
        let data = inbound.subdata(in: readOffset..<end)
        readOffset = end
        completion(data, nil, end == inbound.count, nil)
    }
    public func cancel() { state = .cancelled }
''')
    network += '\npublic struct NWError: Error {}\n'
    files['Network.swift'] = network
    files['MessageReader.swift'] = (root / 'iOSClient/MessageReader.swift').read_text()
    cap_start = stream.index('            let cap = StreamMessage.hostPayloadLimit(for: header.kind)', stream.index('private func probeMove('))
    cap_end = stream.index('            let next =', cap_start)
    cap_body = stream[cap_start:cap_end]
    files['ProbeCap.swift'] = '''import Foundation
import Network
import StreamProtocol
final class ProbeCap {
    var accepted = 0
    func receive(_ header: StreamHeader, c: NWConnection) {
''' + cap_body + '''
        accepted += 1
    }
}
'''
    manifest['legacyProbeCap'] = hashlib.sha256(cap_body.encode()).hexdigest()
    for name in ['Framework.swift', 'main.swift']:
        files[name] = (here / name).read_text()
    native_route_start = stream.index('        case .epochParameterSets, .epochFrame:')
    native_route_end = stream.index('        case .parameterSets:', native_route_start)
    media_body = stream[native_route_start:native_route_end]
    files['Accounting.swift'] = '''import Foundation
import Network
import StreamProtocol
final class FrameReceiver {
// SAMPLE_CEILING
    var frameAgeSamples: [Double] = []
    var frameCounter = 0
    var connection: NWConnection?
    var visionWireBinding: (peer: ObjectIdentifier, binding: VisionInputBinding)?
    var visionMediaPS: (epoch: UUID, ps: ParameterSets)?
    let displayView = EpochDisplay()
''' + block(stream, 'private func noteVideoFrame(').replace('private ', '') + '''
    func receive(_ header: StreamHeader, data: Data, peer: NWConnection) {
        switch header.kind {
''' + media_body + '''
        default: break
        }
    }
}
'''
    ceiling = next(line.strip().replace('private ', '') for line in stream.splitlines() if line.strip().startswith('private static let sampleCeilingMs ='))
    files['Accounting.swift'] = files['Accounting.swift'].replace('// SAMPLE_CEILING', ceiling)
    manifest['frameSampleCeiling'] = hashlib.sha256(ceiling.encode()).hexdigest()
    manifest['nativeLifecycle'] = hashlib.sha256(body.encode()).hexdigest()
    manifest['hostMethods'] = hashlib.sha256(host.encode()).hexdigest()
    manifest['mediaReceiver'] = hashlib.sha256(media_body.encode()).hexdigest()
    return files, manifest

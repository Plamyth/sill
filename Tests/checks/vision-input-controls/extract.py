import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_platform import select_platform

ROOT = Path(__file__).resolve().parents[3]

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

def fixture():
    stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
    markers = ['var connection: NWConnection?', 'private static func visionInputBytes(', 'private func applyVisionInputCatalog(', 'private func visionPresentationChanged(', 'private func observeVisionInputCatalog(', 'func cancelVisionInputs(', 'private func finishMove(']
    pieces = {m: block(stream, m) for m in markers}
    pieces['sendInput'] = block(stream, 'func sendInput(')
    hello = block(stream, 'private static let helloPayload: Data =') + '()'
    pieces['helloPayload'] = select_platform(hello, vision=True)
    pieces['iPadHelloPayload'] = select_platform(hello, vision=False).replace('helloPayload:', 'iPadHelloPayload:')
    teardown = block(stream, 'func tearDown(status:')
    start = teardown.index('#if os(visionOS)')
    pieces['teardownInput'] = 'func teardownInput() {\n' + teardown[start:teardown.index('        abandonMove()')] + '\n}'
    move = block(stream, 'private func finishMoveAfterInputDrain(')
    start = move.index('        #if os(visionOS)')
    pieces['moveInputReset'] = move[start:move.index('#endif', start) + len('#endif')]
    pieces['bindingState'] = block(stream, '@Published private(set) var visionInputBinding =')
    pieces['resumeSource'] = block(stream, 'if let resume = self.resumeSource')
    pieces['resumeMethod'] = 'func resumeCatalog(_ list: WindowList) {\n' + pieces['resumeSource'] + '\n}'
    body = '\n'.join(select_platform(p, vision=True) for name, p in pieces.items() if name not in ['moveInputReset', 'bindingState', 'resumeSource'])
    overlay = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
    pieces['takeVisionKeyReleases'] = block(overlay, 'func takeVisionKeyReleases()')
    stub = (Path(__file__).parent / 'Standins.swift').read_text().replace('// OVERLAY_DRAIN', pieces['takeVisionKeyReleases']).replace('// MOVE_INPUT_RESET', select_platform(pieces['moveInputReset'], vision=True)).replace('// BINDING_STATE', pieces['bindingState'].replace('@Published', '@SwiftUI.Published', 1))
    files = {'Client.swift': stub.replace('// EXTRACTED', body), 'main.swift': (Path(__file__).parent / 'main.swift').read_text(), 'Network.swift': (Path(__file__).parent / 'Network.swift').read_text(), 'SwiftUI.swift': (Path(__file__).parent / 'SwiftUI.swift').read_text()}
    for name in ['Sources/StreamProtocol/Input.swift', 'Sources/SillHost/KeyStrokes.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionRemoteKey.swift', 'Tests/checks/vision-input-controls/SourceInputFence.swift']:
        files[name] = (ROOT / name).read_text()
    files['Tests/checks/vision-input-controls/SourceInputFence.swift'] = (ROOT / 'Sources/SillHost/SourceInputFence.swift').read_text()
    pieces['sourceInputFence'] = files['Tests/checks/vision-input-controls/SourceInputFence.swift']
    for path in ['Tests/vision-pointer/main.swift','visionOSClient/VisionInputFence.swift','visionOSClient/VisionTransition.swift','Tests/checks/fence/main.swift']:
        files[path] = (ROOT/path).read_text()
    for path in sorted((ROOT/'Sources/StreamProtocol').glob('*.swift')):
        files[str(path.relative_to(ROOT))] = path.read_text()
    files['mutants/debt/Client.swift'] = files['Client.swift'].replace('self?.visionInputDebt.record(input, on: expected)', '_ = input', 1)
    files['mutants/route/SessionLink.swift'] = files['iOSClient/SessionLink.swift'].replace('guard current === expected else { return false }', '', 1)
    admission = '        guard let input = visionInputBinding.capture(event), let permit = visionInputPermit else { return }\n'
    late = files['Client.swift'].replace(admission, '', 1).replace('        let bytes = Self.visionInputBytes(input)\n', '', 1)
    files['mutants/capture/Client.swift'] = late.replace('            let accepted = self.link.send(bytes, onlyOn: expected, permit: permit)', '            guard let input = self.visionInputBinding.capture(event), let permit = self.visionInputPermit else { return }\n            let bytes = Self.visionInputBytes(input)\n            let accepted = self.link.send(bytes, onlyOn: expected, permit: permit)', 1)
    files['mutants/generation/VisionInputDebt.swift'] = files['visionOSClient/VisionInputDebt.swift'].replace('Self(event: event, generation: generation, videoEpoch: videoEpoch)', 'Self(event: event, generation: nil, videoEpoch: videoEpoch)', 1)
    files['mutants/admission/Client.swift'] = files['Client.swift'].replace(admission, '        let input = visionInputBinding.capture(event) ?? CapturedVisionInput(event: event, generation: nil)\n        let permit = visionInputPermit\n', 1)
    files['mutants/controls/VisionInputSession.swift'] = files['visionOSClient/VisionInputSession.swift'].replace(' && client.visionInputBinding.isConfirmed', '', 1)
    manifest = {m: hashlib.sha256(p.encode()).hexdigest() for m, p in pieces.items()}
    return files, manifest

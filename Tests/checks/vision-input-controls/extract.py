import hashlib
from pathlib import Path

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
    markers = ['var connection: NWConnection?', 'private static func visionInputBytes(', 'private func applyVisionInputCatalog(', 'func cancelVisionInputs(', 'private func finishMove(']
    pieces = {m: block(stream, m) for m in markers}
    send = block(stream, 'func sendInput(')
    if '#if os(visionOS)' in send:
        send = send[:send.index('#else')] + '\n}'
    pieces['sendInput'] = send
    hello = block(stream, 'private static let helloPayload: Data =') + '()'
    hello = hello.replace('#if DEBUG', '#if NEVER_FIXTURE_DEBUG')
    def hello_for(vision):
        selected = hello
        for condition, enabled in [('NEVER_FIXTURE_DEBUG', False), ('os(visionOS)', vision)]:
            begin = selected.index('#if ' + condition)
            end = selected.index('#endif', begin)
            content = selected[selected.index('\n', begin) + 1:end] if enabled else ''
            selected = selected[:begin] + content + selected[end + len('#endif'):]
        return selected
    pieces['helloPayload'] = hello_for(True)
    pieces['legacyHelloPayload'] = hello_for(False).replace('helloPayload:', 'legacyHelloPayload:')
    teardown = block(stream, 'func tearDown(status:')
    pieces['teardownInput'] = 'func teardownInput() {\n' + teardown[teardown.index('#if os(visionOS)'):teardown.index('        abandonMove()')] + '\n}'
    move = block(stream, 'private func finishMoveAfterInputDrain(')
    start = move.index('        #if os(visionOS)')
    pieces['moveInputReset'] = move[start:move.index('#endif', start) + len('#endif')]
    pieces['bindingState'] = next(line.strip() for line in stream.splitlines() if '@Published private(set) var visionInputBinding =' in line)
    body = '\n'.join(p for name, p in pieces.items() if name not in ['moveInputReset', 'bindingState']).replace('#if os(visionOS)', '').replace('#else\n        finishMoveAfterInputDrain(c, kind: kind, kept: kept)\n        #endif', '').replace('#endif', '')
    overlay = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
    pieces['takeVisionKeyReleases'] = block(overlay, 'func takeVisionKeyReleases()')
    stub = (Path(__file__).parent / 'Standins.swift').read_text().replace('// OVERLAY_DRAIN', pieces['takeVisionKeyReleases']).replace('// MOVE_INPUT_RESET', pieces['moveInputReset'].replace('#if os(visionOS)', '').replace('#endif', '')).replace('// BINDING_STATE', pieces['bindingState'].replace('@Published', '@SwiftUI.Published', 1))
    files = {'Client.swift': stub.replace('// EXTRACTED', body), 'main.swift': (Path(__file__).parent / 'main.swift').read_text(), 'Network.swift': (Path(__file__).parent / 'Network.swift').read_text(), 'SwiftUI.swift': (Path(__file__).parent / 'SwiftUI.swift').read_text()}
    for name in ['Sources/StreamProtocol/Input.swift', 'Sources/SillHost/KeyStrokes.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionRemoteKey.swift', 'Tests/checks/vision-input-controls/SourceInputFence.swift']:
        files[name] = (ROOT / name).read_text()
    for path in ['Tests/vision-pointer/main.swift','visionOSClient/VisionInputFence.swift','visionOSClient/VisionTransition.swift','Tests/checks/fence/main.swift']:
        files[path] = (ROOT/path).read_text()
    for path in sorted((ROOT/'Sources/StreamProtocol').glob('*.swift')):
        files[str(path.relative_to(ROOT))] = path.read_text()
    files['mutants/debt/Client.swift'] = files['Client.swift'].replace('self?.visionInputDebt.record(input, on: expected)', '_ = input', 1)
    files['mutants/route/SessionLink.swift'] = files['iOSClient/SessionLink.swift'].replace('guard current === expected else { return false }', '', 1)
    admission = '        guard let input = visionInputBinding.capture(event) else { return }\n'
    late = files['Client.swift'].replace(admission, '', 1).replace('        let bytes = Self.visionInputBytes(input)\n', '', 1)
    files['mutants/capture/Client.swift'] = late.replace('            let accepted = self.link.send(bytes, onlyOn: expected)', '            guard let input = self.visionInputBinding.capture(event) else { return }\n            let bytes = Self.visionInputBytes(input)\n            let accepted = self.link.send(bytes, onlyOn: expected)', 1)
    files['mutants/generation/VisionInputDebt.swift'] = files['visionOSClient/VisionInputDebt.swift'].replace('Self(event: event, generation: generation)', 'Self(event: event, generation: nil)', 1)
    files['mutants/admission/Client.swift'] = files['Client.swift'].replace(admission, '        let input = visionInputBinding.capture(event) ?? CapturedVisionInput(event: event, generation: nil)\n', 1)
    files['mutants/controls/VisionInputSession.swift'] = files['visionOSClient/VisionInputSession.swift'].replace(' && client.visionInputBinding.isConfirmed', '', 1)
    manifest = {m: hashlib.sha256(p.encode()).hexdigest() for m, p in pieces.items()}
    return files, manifest

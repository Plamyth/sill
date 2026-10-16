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
    markers = ['var connection: NWConnection?', 'private static func visionInputBytes(', 'func cancelVisionInputs(', 'private func finishMove(']
    pieces = {m: block(stream, m) for m in markers}
    send = block(stream, 'func sendInput(')
    if '#if os(visionOS)' in send:
        send = send[:send.index('#else')] + '\n}'
    pieces['sendInput'] = send
    body = '\n'.join(pieces.values()).replace('#if os(visionOS)', '').replace('#else\n        finishMoveAfterInputDrain(c, kind: kind, kept: kept)\n        #endif', '').replace('#endif', '')
    overlay = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
    pieces['takeVisionKeyReleases'] = block(overlay, 'func takeVisionKeyReleases()')
    stub = (Path(__file__).parent / 'Standins.swift').read_text().replace('// OVERLAY_DRAIN', pieces['takeVisionKeyReleases'])
    files = {'Client.swift': stub.replace('// EXTRACTED', body), 'main.swift': (Path(__file__).parent / 'main.swift').read_text(), 'Network.swift': (Path(__file__).parent / 'Network.swift').read_text(), 'SwiftUI.swift': (Path(__file__).parent / 'SwiftUI.swift').read_text()}
    for name in ['Sources/StreamProtocol/Input.swift', 'Sources/SillHost/KeyStrokes.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionRemoteKey.swift']:
        files[name] = (ROOT / name).read_text()
    for path in ['Tests/vision-pointer/main.swift','visionOSClient/VisionInputFence.swift','visionOSClient/VisionTransition.swift','Tests/checks/fence/main.swift']:
        files[path] = (ROOT/path).read_text()
    for path in sorted((ROOT/'Sources/StreamProtocol').glob('*.swift')):
        files[str(path.relative_to(ROOT))] = path.read_text()
    files['mutants/debt/Client.swift'] = files['Client.swift'].replace('self?.visionInputDebt.record(event, on: expected)', '_ = event', 1)
    files['mutants/route/SessionLink.swift'] = files['iOSClient/SessionLink.swift'].replace('guard current === expected else { return false }', '', 1)
    manifest = {m: hashlib.sha256(p.encode()).hexdigest() for m, p in pieces.items()}
    return files, manifest

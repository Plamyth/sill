#!/usr/bin/env python3
"""Compile the actual startup coordinator and extracted client adapters with inert I/O."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_platform import select_platform


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, position = 1, opening + 1
    while depth:
        if position >= len(source):
            raise ValueError('unterminated extraction ' + marker)
        if source.startswith('//', position):
            position = source.find('\n', position)
            if position < 0:
                raise ValueError('unterminated comment ' + marker)
            continue
        if source[position] == '"':
            position += 1
            while source[position] != '"':
                position += 2 if source[position] == '\\' else 1
            position += 1
            continue
        depth += (source[position] == '{') - (source[position] == '}')
        position += 1
    return source[start:position]


def vision(source):
    return select_platform(source.replace('os(iOS) || os(visionOS)', 'os(visionOS)'), vision=True)


def emit(root, output):
    view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    app = block(view, 'struct SillVisionApp: App')
    window = block(view, 'private struct SillVisionWindow: View')
    if '@StateObject private var session = VisionAppSession()' in app or \
       '@StateObject private var session = VisionAppSession()' not in window:
        raise AssertionError('Each native window must own its session, stream view and input')
    if 'openWindow(id: "mac")' not in view or 'WindowGroup(id: "mac")' not in app:
        raise AssertionError('Native concurrent Mac window action missing')
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    home = (root / 'iOSClient/StreamClient+Home.swift').read_text()
    remote = (root / 'iOSClient/StreamClient+Remote.swift').read_text()
    for source, markers in [(stream, ['func setVisionPresentationForeground(', 'private func wentToBackground(',
                                      'func connect(to mac:', 'func disconnect()', 'var connection: NWConnection?']),
                            (remote, ['func cancelPairing(', 'func dialSaved(', 'private func startPairing(']),
                            (home, ['func ask('])]:
        for marker in markers:
            if 'stopSavedMacAutoConnect()' not in vision(block(source, marker)):
                raise ValueError('missing Vision startup cancellation at ' + marker)
    protocol = root / 'Sources/StreamProtocol'
    pieces = {}
    for marker in ['func ask(', 'func startAsk(', 'private func asked(', 'private func askFailed(',
                   'func cancelHomeAsk(', 'private func savePairedAtHome(', 'private func sessionAfterHomePairing(',
                   'private func askedTarget(', 'static func bonjourName(', 'func homeRows(']:
        pieces[marker] = vision(block(home, marker))
    for marker in ['private struct VisionStartupTarget', 'private enum StartupAutoConnection',
                   'func armSavedMacAutoConnect(', 'func stopSavedMacAutoConnect(', 'func rememberPreferredMac(',
                   'func rememberAuthenticatedMac(', 'private func trySavedMacAutoConnect(',
                   'private func tryVisionSavedMacAutoConnect(', 'func homeDecision(', 'func wiredDial(']:
        pieces[marker] = vision(block(stream, marker))
    adapter = (root / 'visionOSClient/StreamClient+VisionAutoConnect.swift').read_text()
    pieces['considerVisionCableBootstrap'] = block(adapter, 'func considerVisionCableBootstrap(')
    pieces['stopVisionCableBootstrap'] = block(adapter, 'func stopVisionCableBootstrap(')
    body = (root / 'Tests/checks/vision-autoconnect/Standins.swift').read_text()
    body = body.replace('/* REAL_CLIENT_METHODS */', '\n'.join(pieces.values()))
    owner = (root / 'visionOSClient/VisionAppSession.swift').read_text()
    owner_methods = '\n'.join(block(owner, marker) for marker in ['func claim(', 'func owns(', 'func release(',
        'func setScenePhase(', 'func suspendPresentation(', 'func start(', 'func setForeground('])
    if 'deinit {' in owner:
        owner_methods += '\n' + block(owner, 'deinit {')
    body = body.replace('/* REAL_OWNER_METHODS */', owner_methods)
    for marker in ['private func dialTarget(', 'private func ended(']:
        pieces[marker] = vision(block(home, marker))
    body = body.replace('/* REAL_DIAL_METHODS */', '\n'.join(pieces[marker] for marker in ['private func dialTarget(', 'private func ended(']))
    target_types = '\n'.join(block(home, marker) for marker in ['struct Target:', 'struct Winner {', 'struct Failed {'])
    body = body.replace('/* REAL_DIAL_TYPES */', target_types)
    body = body.replace('/* REAL_ROW */', block(stream, 'struct FoundMac:'))
    body = body.replace('/* REAL_ASK */', block(home, 'struct HomeAsk:'))
    body += '\n' + (root / 'Tests/checks/vision-autoconnect/scenarios.swift').read_text()
    (output / 'main.swift').write_text(body)
    primitive_markers = {
        'RemoteIdentity.swift': ['public enum Base64URL', 'public enum MacID'],
        'Remote.swift': ['public struct MacAddress:', 'public struct MacInfo:', 'public struct PairResult:'],
        'Pairing.swift': ['public enum RecognitionTag'],
    }
    primitives = 'import Foundation\nimport CryptoKit\nimport Security\n'
    for filename, markers in primitive_markers.items():
        text = (protocol / filename).read_text()
        for marker in markers:
            primitives += block(text, marker) + '\n'
    (output / 'ProtocolTypes.swift').write_text(primitives)
    (output / 'SavedMacs.swift').write_text((root / 'iOSClient/SavedMacs.swift').read_text().replace('import StreamProtocol\n', ''))
    (output / 'Status.swift').write_text('import Foundation\n' + block((root / 'visionOSClient/VisionAutoConnectStatus.swift').read_text(), 'struct VisionAutoConnectStatus:'))
    return {marker: hashlib.sha256(text.encode()).hexdigest() for marker, text in pieces.items()}


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: run.py <source-root> <output-dir>')
    root, output = (Path(value).resolve() for value in sys.argv[1:])
    if output == root or root in output.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('use a new isolated output directory outside the source root')
    output.mkdir(parents=True, exist_ok=True)
    record = {'schema': 1, 'scope': 'pure policy and actual extracted startup/ask/save adapters; inert typed Network, key, defaults, timer and session I/O; no device or host acceptance', 'commands': [], 'exitCode': 2}
    source_paths = [root / name for name in [
        'visionOSClient/VisionCableBootstrap.swift', 'visionOSClient/VisionAutoConnectStatus.swift',
        'visionOSClient/StreamClient+VisionAutoConnect.swift', 'visionOSClient/VisionAppSession.swift',
        'iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Home.swift', 'iOSClient/StreamClient+Remote.swift', 'iOSClient/SavedMacs.swift',
        'iOSClient/DiscoveryPolicy.swift', 'Sources/StreamProtocol/RemoteIdentity.swift',
        'Sources/StreamProtocol/Remote.swift', 'Sources/StreamProtocol/Pairing.swift',
        'Sources/StreamProtocol/SafeText.swift', 'Tests/checks/vision-autoconnect/Standins.swift',
        'Tests/checks/vision-autoconnect/scenarios.swift', 'Tests/checks/vision-autoconnect/run.py']]
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}
    record['sourceSHA256'] = hashes
    try:
        record['extractedSHA256'] = emit(root, output)
        sources = [root / 'visionOSClient/VisionCableBootstrap.swift', root / 'iOSClient/DiscoveryPolicy.swift',
                   root / 'Sources/StreamProtocol/SafeText.swift', output / 'ProtocolTypes.swift',
                   output / 'SavedMacs.swift', output / 'Status.swift', output / 'main.swift']
        command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'module-cache'), *map(str, sources), '-o', str(output / 'checks')]
        for label, command in [('compile', command), ('runtime', [str(output / 'checks')])]:
            try:
                result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                        timeout=180 if label == 'compile' else 30)
            except subprocess.TimeoutExpired as error:
                partial = error.stdout or b''
                if isinstance(partial, bytes):
                    partial = partial.decode(errors='replace')
                (output / (label + '.log')).write_text(partial)
                raise
            (output / (label + '.log')).write_text(result.stdout)
            record['commands'].append({'command': command, 'exitCode': result.returncode})
            if result.returncode:
                raise RuntimeError(label + ' failed; read ' + label + '.log')
        record['checks'] = [line[3:] for line in result.stdout.splitlines() if line.startswith('ok ')]
        record['exitCode'] = 0
    except Exception as error:
        record['errorFixed'] = type(error).__name__
        record['failure'] = str(error)
    record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in hashes.items())
    if not record['sourceUnchanged']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'exitCode': record['exitCode'], 'checks': len(record.get('checks', [])), 'sourceUnchanged': record['sourceUnchanged'], 'result': str(output / 'result.json')}))
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

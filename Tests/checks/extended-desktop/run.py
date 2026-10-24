#!/usr/bin/env python3
"""Run pure host checks from hashed, volatile Mini input. This is not a task-transfer receipt."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def sha(data):
    return hashlib.sha256(data).hexdigest()


coordinator = (ROOT / 'Sources/SillHost/StreamCoordinator.swift').read_text()
catalog = (ROOT / 'Sources/SillHost/WindowCatalog.swift').read_text()
desktop = (ROOT / 'Sources/SillHost/ExtendedDesktop.swift').read_text()
admit = block(coordinator, 'private func requestExtendedDesktop(').replace('private func', 'func', 1)
fixture = (HERE / 'Fixtures.swift').read_text().replace('// COORDINATOR_METHOD', admit)
fixture = fixture.replace('// DISPLAY_INFO\n', block((ROOT / 'Sources/StreamProtocol/Switcher.swift').read_text(), 'public struct DisplayInfo:') + '\n')
display_construction = block(catalog, 'private func updateDisplays(').split('return DisplayInfo(', 1)[1].split('\n        }', 1)[0]
fixture = fixture.replace('// DISPLAY_INFO_CONSTRUCTION', ('return DisplayInfo(' + display_construction).replace('CGMainDisplayID()', 'mainID'))
fixture = fixture.replace('// VIEWPORT_METHOD', block(coordinator, 'private func updateExtendedDesktopViewport(').replace('private func', 'func', 1))
fixture = fixture.replace('// HELLO_DESKTOP', next(line.strip().replace('self.', '') for line in
    block(coordinator, 'server.onClientHello =').splitlines() if 'requestExtendedDesktop(for:' in line))
peer_message = block(coordinator, 'private func handlePeerMessage(')
peer_viewport = peer_message.split('case .viewport:', 1)[1].split('case .input:', 1)[0]
peer_fixture = peer_message.split('switch message.kind {', 1)[0] + 'switch message.kind {\ncase .viewport:' + peer_viewport + '\ndefault: return false\n}\nreturn true\n}'
fixture = fixture.replace('// PEER_VIEWPORT_METHOD', peer_fixture.replace('private func', 'func', 1)
                          .replace('StreamMessage', 'ViewportMessage').replace('PeerStreamSession', 'PeerFixture'))
disconnected = block(coordinator, 'server.onClientDisconnected =')
fixture = fixture.replace('// DISCONNECT_DESKTOP', disconnected[disconnected.index('self.extendedDesktop.release(id)'):disconnected.index('if let lane =')].replace('self.', ''))
fixture = fixture.replace('// ONLINE_WAIT_METHOD', block(desktop, 'private static func waitUntilOnline(').replace('private static', 'static', 1))
fixture = fixture.replace('// CATALOG_METHODS', '\n'.join(block(catalog, signature) for signature in [
    'func setExtendedDesktopDisplay(', 'static func admitsDisplay('
]))
inputs = {
    'ExtendedDesktop.swift': desktop.split('// MARK: macOS display adapter')[0].replace('import StreamProtocol\n', ''),
    'Viewport.swift': 'import Foundation\n' + block((ROOT / 'Sources/StreamProtocol/Viewport.swift').read_text(), 'public struct Viewport:'),
    'DisplayInventory.swift': (ROOT / 'Sources/SillHost/DisplayInventory.swift').read_text().replace('import StreamProtocol\n', ''),
    'Fixtures.swift': fixture,
    'main.swift': (HERE / 'main.swift').read_text(),
}

assert 'self.requestExtendedDesktop(for: connection, hello: hello)' in block(coordinator, 'server.onClientHello =')
assert 'self.extendedDesktop.release(id)' in block(coordinator, 'server.onClientDisconnected =')
assert 'self.extendedDesktopViewports[id] = nil' in block(coordinator, 'server.onClientDisconnected =')
assert 'self.extendedDesktopEligible.remove(id)' in block(coordinator, 'server.onClientDisconnected =')
assert 'extendedDesktop.shutdown()' in block(coordinator, 'package func shutdownForExit(')
assert 'extendedDesktopViewports.removeAll()' in block(coordinator, 'package func shutdownForExit(')
assert 'extendedDesktopEligible.removeAll()' in block(coordinator, 'package func shutdownForExit(')
assert 'if !self.independentStreamsEnabled' not in block(coordinator, 'server.onClientHello =')
assert 'extendedDesktopControl: synthetic ? nil : 1' in block(coordinator, 'private func listMessage(')
viewport_case = coordinator.split('case .viewport:', 1)[1].split('case .pairingWanted:', 1)[0]
assert viewport_case.index('updateExtendedDesktopViewport(v, from: connection)') < viewport_case.index('viewport = v')
assert 'extendedDesktop.checkDisplay()' in block(coordinator, 'private func displaysChanged(')
assert 'ownedID: extendedDesktopID' in block(catalog, 'private func updateDisplays(')
assert 'id == extendedDesktopID ? ExtendedDesktop.name' in block(catalog, 'private func updateDisplays(')
assert 'catalog?.setExtendedDesktopDisplay($0)' in desktop
assert 'self.publishID(display.id)' in desktop
assert 'CGConfigureDisplayMirrorOfDisplay(config, display.displayID, kCGNullDirectDisplay)' in desktop
assert 'CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay' in desktop
assert 'widthPt: dimensions.widthPt, heightPt: dimensions.heightPt' in desktop
assert 'scale: dimensions.scale, refreshHz: 60' in desktop
assert 'CGSize(width: display.widthPt, height: display.heightPt)' in block(desktop, 'private static func configure(')
valid = block(desktop, 'private static func valid(')
assert 'CGSize(width: display.widthPt, height: display.heightPt)' in valid
assert 'pixels.width == display.widthPt * display.scale && pixels.height == display.heightPt * display.scale' in valid
assert 'attempted < 4, Date() < deadline' in desktop
assert 'WindowSizer.axWindow' not in desktop
assert 'extendedDesktop' not in block(coordinator, 'private func applyViewportToActiveWindow(')

paths = [ROOT / 'Sources/SillHost' / name for name in ['ExtendedDesktop.swift', 'StreamCoordinator.swift', 'WindowCatalog.swift', 'VirtualStage.swift', 'VirtualDisplay.swift', 'DisplayInventory.swift']]
paths += list((ROOT / 'Sources/StreamProtocol').glob('*.swift'))
paths += [HERE / name for name in ['Fixtures.swift', 'main.swift', 'run.py', 'remote.py']]
before = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
hashes = {name: sha(source.encode()) for name, source in inputs.items()}
payload = json.dumps({'sources': {name: base64.b64encode(source.encode()).decode() for name, source in inputs.items()}, 'hashes': hashes}).encode()
if '--local-sdk' in sys.argv:
    output = Path(sys.argv[sys.argv.index('--output-dir') + 1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    for name, source in inputs.items():
        (output / name).write_text(source)
    command = ['xcrun', '--sdk', 'macosx', 'swiftc', '-sdk', sdk, '-parse-as-library',
               '-module-cache-path', str(output / 'cache')]
    command += [str(output / name) for name in inputs] + ['-o', str(output / 'checks')]
    compiled = subprocess.run(command, capture_output=True, text=True)
    checked = subprocess.run([str(output / 'checks')], capture_output=True, text=True) if compiled.returncode == 0 else None
    log = compiled.stdout + compiled.stderr + (checked.stdout + checked.stderr if checked else '')
    (output / 'checks.log').write_text(log)
    code = checked.returncode if checked else compiled.returncode
    unchanged = all(sha((ROOT / name).read_bytes()) == digest for name, digest in before.items())
    (output / 'receipt.json').write_text(json.dumps({'scope': 'Extracted production pure checks with explicit macOS SDK; no app, device or service execution.',
        'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'sdk': sdk, 'sourceHashes': before, 'emittedHashes': hashes, 'sourceUnchanged': unchanged,
        'compileExit': compiled.returncode, 'checkExit': checked.returncode if checked else None}, indent=2) + '\n')
    print(log)
    print('RECEIPT ' + str(output / 'receipt.json'))
    sys.exit(code if unchanged else 2)
runner = (HERE / 'remote.py').read_text()
audit = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / '.audit'
audit.mkdir(exist_ok=True)
receipt_path = audit / ('extended-desktop-' + sha(payload + runner.encode())[:12] + '.json')
if receipt_path.exists():
    raise SystemExit('receipt already exists; do not repeat identical input')


def containers():
    result = subprocess.run(['docker', '--context', 'cargo24-mini', 'ps', '-a', '--format', '{{.ID}} {{.Names}} {{.Status}}'],
                            capture_output=True, text=True, timeout=20)
    return {'exitCode': result.returncode, 'rows': result.stdout.splitlines()}


services_before = containers()
process = subprocess.run(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--',
    'python3', '-B', '-c', runner], input=payload, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
log = process.stdout.decode(errors='replace')
print(log)
records = [json.loads(line.removeprefix('RESULT_JSON ')) for line in log.splitlines() if line.startswith('RESULT_JSON ')]
receipt = {
    'scope': 'Independent pure checks via volatile RAM input. No source-guard transfer, SDK host build, running host or device validation.',
    'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'senderReceiverMatch': 'INPUT_SHA256 ' + sha(payload) in log,
    'sourceUnchanged': all(sha((ROOT / name).read_bytes()) == digest for name, digest in before.items()),
    'sourceHashes': before, 'emittedHashes': hashes, 'exitCode': process.returncode,
    'remote': records[-1] if records else None,
    'containersBefore': services_before, 'containersAfter': containers(),
}
receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
print('RECEIPT ' + str(receipt_path))
if process.returncode or not records or not receipt['senderReceiverMatch'] or not receipt['sourceUnchanged']:
    sys.exit(process.returncode or 2)
remote = records[-1]
sys.exit(0 if remote.get('sourceRemoved') and remote.get('inputHashesMatched') and remote.get('exitCode') == 0 else 2)

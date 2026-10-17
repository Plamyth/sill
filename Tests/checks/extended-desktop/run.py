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
fixture = fixture.replace('// ONLINE_WAIT_METHOD', block(desktop, 'private static func waitUntilOnline(').replace('private static', 'static', 1))
fixture = fixture.replace('// CATALOG_METHODS', '\n'.join(block(catalog, signature) for signature in [
    'func setExtendedDesktopDisplay(', 'static func admitsDisplay('
]))
inputs = {
    'ExtendedDesktop.swift': desktop.split('// MARK: macOS display adapter')[0],
    'DisplayInventory.swift': (ROOT / 'Sources/SillHost/DisplayInventory.swift').read_text().replace('import StreamProtocol\n', ''),
    'Fixtures.swift': fixture,
    'main.swift': (HERE / 'main.swift').read_text(),
}

assert 'self.requestExtendedDesktop(for: connection, hello: hello)' in block(coordinator, 'server.onClientHello =')
assert 'self.extendedDesktop.release(id)' in block(coordinator, 'server.onClientDisconnected =')
assert 'extendedDesktop.shutdown()' in block(coordinator, 'package func shutdownForExit(')
assert 'extendedDesktop.checkDisplay()' in block(coordinator, 'private func displaysChanged(')
assert 'ownedID: extendedDesktopID' in block(catalog, 'private func updateDisplays(')
assert 'id == extendedDesktopID ? ExtendedDesktop.name' in block(catalog, 'private func updateDisplays(')
assert 'CGConfigureDisplayMirrorOfDisplay(config, display.displayID, kCGNullDirectDisplay)' in desktop
assert 'CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay' in desktop
assert 'widthPt: 1024, heightPt: 768' in desktop and 'scale: 2, refreshHz: 60' in desktop
assert 'attempted < 4, Date() < deadline' in desktop
assert 'WindowSizer.axWindow' not in desktop
assert 'extendedDesktop' not in block(coordinator, 'private func applyViewportToActiveWindow(')

paths = [ROOT / 'Sources/SillHost' / name for name in ['ExtendedDesktop.swift', 'StreamCoordinator.swift', 'WindowCatalog.swift', 'VirtualStage.swift', 'VirtualDisplay.swift', 'DisplayInventory.swift']]
paths += list((ROOT / 'Sources/StreamProtocol').glob('*.swift'))
paths += [HERE / name for name in ['Fixtures.swift', 'main.swift', 'run.py', 'remote.py']]
before = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
hashes = {name: sha(source.encode()) for name, source in inputs.items()}
payload = json.dumps({'sources': {name: base64.b64encode(source.encode()).decode() for name, source in inputs.items()}, 'hashes': hashes}).encode()
runner = (HERE / 'remote.py').read_text()
audit = ROOT / '.audit'
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

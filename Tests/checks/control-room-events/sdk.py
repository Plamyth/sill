#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
assert output.is_relative_to(Path(archive['path']).resolve())
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
sources = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift')) + [
    root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift',
    *[root / f'iOSClient/{name}.swift' for name in [
        'IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator']]]
inputs = [protocol, *sources, Path(__file__)]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
# Same iOS SDK typecheck inputs as linked-obsidian-notes/run.py; no app build or signing.
base = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-ios27.0',
        '-swift-version', '5', '-module-cache-path', str(output / 'modules')]
commands = [base + ['-emit-module', '-module-name', 'StreamProtocol', str(protocol),
                    '-emit-module-path', str(output / 'StreamProtocol.swiftmodule')],
            base + ['-parse-as-library', '-I', str(output), '-typecheck', *map(str, sources)]]
codes = []
for index, command in enumerate(commands):
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (output / f'typecheck-{index}.log').write_text(result.stdout)
    codes.append(result.returncode)
    if result.returncode:
        print(result.stdout)
        break
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(output / 'sdk-result.json').write_text(json.dumps({
    'sdk': sdk, 'commands': commands, 'exitCodes': codes, 'sourceHashes': hashes,
    'sourceHashesAfter': after, 'sourceUnchanged': hashes == after,
    'appBuilt': False, 'deviceExecuted': False}, indent=2) + '\n')
print(f'iOS SDK typecheck exitCodes={codes}, sourceUnchanged={hashes == after}')
sys.exit(0 if len(codes) == 2 and codes == [0, 0] and hashes == after else 1)

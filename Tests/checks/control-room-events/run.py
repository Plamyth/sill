#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
assert output.is_relative_to(Path(archive['path']).resolve())
stage = output / 'foundation-input'
stage.mkdir(parents=True, exist_ok=True)
projection = root / 'iOSClient/CanvasBridge/ControlRoomProjection.swift'
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
text = model.read_text()
voice = text[text.index('struct VoiceSession:'):text.index('\nstruct VoiceProjection:')]
(stage / 'VoiceSession.swift').write_text('import Foundation\n' + voice + '\n')
(stage / 'ControlRoomProjection.swift').write_bytes(projection.read_bytes())
for name in ['main.swift', 'SourceSessions.swift', 'PublicResults.swift', 'BrainTrinity.swift', 'fixture.json',
             'android-mobile-control-events-v1.json', 'android-fixture-provenance.json',
             'public-fixtures.json', 'public-fixture-provenance.json']:
    (stage / name).write_bytes(Path(__file__).with_name(name).read_bytes())
assert hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest() == 'a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454'
provenance = json.loads((stage / 'android-fixture-provenance.json').read_text())
assert provenance['sourceCommit'] == 'e5f931657dba5b2d3d4c04b547a7a17da3ac660b'
assert provenance['sha256'] == '9fb6288d6ac3d68f4d743d8703b091f263664d239248b53e6ba82d8cb554b319'
assert hashlib.sha256((stage / 'android-mobile-control-events-v1.json').read_bytes()).hexdigest() == provenance['sha256']
public_provenance = json.loads((stage / 'public-fixture-provenance.json').read_text())
public_hash = hashlib.sha256((stage / 'public-fixtures.json').read_bytes()).hexdigest()
assert public_hash == public_provenance['projectedOnlySHA256'] == 'e40d4eaaf634854ff62612bf8c4fad2d33248c2aabf2b93213275713ce4da1fc'
public = json.loads((stage / 'public-fixtures.json').read_text())
assert public['producerCommit'] == '9a91483f5e054ad8f30e9a1d43d8e7fd91740c6a'
assert public['producerTree'] == '4f7581661680f466a363ad7199ae1db54874163e'
assert len(public['cases']) == public_provenance['cases'] == 6
def public_only(value):
    if isinstance(value, dict):
        return 'raw' not in value and all(public_only(item) for item in value.values())
    return not isinstance(value, list) or all(public_only(item) for item in value)
assert public_provenance['rawCopied'] is False and public_only(public)
(stage / 'run.sh').write_text('''#!/bin/sh
set -eu
swiftc -swift-version 5 -parse-as-library VoiceSession.swift ControlRoomProjection.swift SourceSessions.swift PublicResults.swift BrainTrinity.swift main.swift -o checks
./checks
''')
inputs = [projection, model, Path(__file__), *[p for p in Path(__file__).parent.iterdir() if p.is_file()]]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
stage_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.iterdir() if p.is_file()}
result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
    '--owner', '01a13ace-e372-7ed1-9946-149df37ee1c3', '--job', 'ipad-bt-observation-20261027', '--', 'sh', 'run.sh'],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output / 'foundation.log').write_text(result.stdout)
print(result.stdout, end='')
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
receipts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"receipt":')]
cleanup_verified = bool(receipts) and receipts[-1]['cleanup_verified'] is True
code = result.returncode or (0 if hashes == after and cleanup_verified else 1)
(output / 'foundation-result.json').write_text(json.dumps({
    'sourceSHA256': hashlib.sha256(projection.read_bytes()).hexdigest(),
    'fixtureSHA256': hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest(),
    'androidFixtureSHA256': provenance['sha256'],
    'publicFixtureSHA256': public_hash, 'rawCopied': False,
    'sourceHashes': hashes, 'sourceHashesAfter': after, 'sourceUnchanged': hashes == after,
    'transferredInputHashes': stage_hashes, 'miniReceipt': receipts[-1] if receipts else None,
    'cleanupVerified': cleanup_verified,
    'exitCode': code, 'networkServiceUsed': False, 'deviceExecuted': False}, indent=2) + '\n')
sys.exit(code)

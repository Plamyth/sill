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
for name in ['main.swift', 'SourceSessions.swift', 'fixture.json', 'android-mobile-control-events-v1.json', 'android-fixture-provenance.json']:
    (stage / name).write_bytes(Path(__file__).with_name(name).read_bytes())
assert hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest() == 'a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454'
provenance = json.loads((stage / 'android-fixture-provenance.json').read_text())
assert provenance['sourceCommit'] == 'e5f931657dba5b2d3d4c04b547a7a17da3ac660b'
assert provenance['sha256'] == '9fb6288d6ac3d68f4d743d8703b091f263664d239248b53e6ba82d8cb554b319'
assert hashlib.sha256((stage / 'android-mobile-control-events-v1.json').read_bytes()).hexdigest() == provenance['sha256']
(stage / 'run.sh').write_text('''#!/bin/sh
set -eu
swiftc -swift-version 5 -parse-as-library VoiceSession.swift ControlRoomProjection.swift SourceSessions.swift main.swift -o checks
./checks
''')
result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
    '--owner', '01a13ace-e372-7ed1-9946-149df37ee1c3', '--job', 'ipad-source-sessions-foundation', '--', 'sh', 'run.sh'],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output / 'foundation.log').write_text(result.stdout)
print(result.stdout, end='')
(output / 'foundation-result.json').write_text(json.dumps({
    'sourceSHA256': hashlib.sha256(projection.read_bytes()).hexdigest(),
    'fixtureSHA256': hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest(),
    'androidFixtureSHA256': provenance['sha256'],
    'exitCode': result.returncode, 'networkServiceUsed': False, 'deviceExecuted': False}, indent=2) + '\n')
sys.exit(result.returncode)

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
for name in ['main.swift', 'fixture.json']:
    (stage / name).write_bytes(Path(__file__).with_name(name).read_bytes())
assert hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest() == 'a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454'
(stage / 'run.sh').write_text('''#!/bin/sh
set -eu
swiftc -swift-version 5 -parse-as-library VoiceSession.swift ControlRoomProjection.swift main.swift -o checks
./checks
''')
result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
    '--owner', '01a13ace-e372-7ed1-9946-149df37ee1c3', '--job', 'native-control-events-foundation', '--', 'sh', 'run.sh'],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output / 'foundation.log').write_text(result.stdout)
print(result.stdout, end='')
(output / 'foundation-result.json').write_text(json.dumps({
    'sourceSHA256': hashlib.sha256(projection.read_bytes()).hexdigest(),
    'fixtureSHA256': hashlib.sha256((stage / 'fixture.json').read_bytes()).hexdigest(),
    'exitCode': result.returncode, 'networkServiceUsed': False, 'deviceExecuted': False}, indent=2) + '\n')
sys.exit(result.returncode)

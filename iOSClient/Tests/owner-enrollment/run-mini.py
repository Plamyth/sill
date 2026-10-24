"""지정된 작업 폴더 안의 최소 입력만 Mini에 한시적으로 전달한다."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
paths = ['Sources/StreamProtocol/RemoteIdentity.swift', 'iOSClient/IPadEnrollmentJSON.swift',
    'iOSClient/IPadEnrollmentProtocol.swift', 'iOSClient/IPadDeviceEnrollment.swift',
    'iOSClient/Tests/owner-enrollment/run.py', 'iOSClient/Tests/owner-enrollment/main.swift',
    'iOSClient/Tests/owner-enrollment/fixtures/device-enrollment-golden-v2.json',
    'iOSClient/Tests/owner-enrollment/fixtures/device-enrollment-readback-golden.json']
paths += ['Sources/StreamProtocol/AudioRouting.swift', 'Sources/StreamProtocol/StreamMessage.swift',
    'iOSClient/IPadEnrollmentTransport.swift', 'iOSClient/IPadEnrollmentStore.swift', 'iOSClient/OwnerBootstrapState.swift',
    'iOSClient/Tests/owner-enrollment/adapters.swift']
paths += ['Sources/StreamProtocol/OwnerMacBootstrap.swift', 'Sources/StreamProtocol/AddressParser.swift',
    'iOSClient/StreamClient+OwnerEnrollment.swift', 'iOSClient/Tests/owner-enrollment/runtime.swift',
    'iOSClient/Tests/owner-enrollment/signed-payload.swift', 'iOSClient/Tests/owner-enrollment/renewal.swift']
suite = 'pure'
command = ['python3', 'iOSClient/Tests/owner-enrollment/run.py']
if sys.argv[1:] == ['--bootstrap']:
    suite = 'bootstrap'
    paths = [str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/StreamProtocol').glob('*.swift')]
    paths += [str(p.relative_to(ROOT)) for p in (ROOT / 'iOSClient/Tests/owner-bootstrap').iterdir() if p.suffix in {'.py', '.swift'}]
    paths += ['iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Remote.swift', 'iOSClient/StreamClient+Home.swift',
        'iOSClient/StreamClient+OwnerBootstrap.swift', 'iOSClient/SavedMacs.swift', 'iOSClient/OwnerBootstrapState.swift',
        'iOSClient/RemoteConnector.swift', 'iOSClient/RemoteDialPolicy.swift', 'iOSClient/DiscoveryPolicy.swift']
    command = ['python3', 'iOSClient/Tests/owner-bootstrap/run.py']
elif sys.argv[1:]:
    raise SystemExit('지원하지 않는 검사 인자')
hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
(ROOT / f'.audit/ipad-owner-receipt-{suite}-input.json').write_text(json.dumps(hashes, indent=2) + '\n')
with tempfile.TemporaryDirectory(prefix='pure-input-', dir=ROOT.parent) as temp:
    for path in paths:
        target = Path(temp) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', temp,
        '--owner', '01a13ace-e372-7ed1-9946-149df37ee1c3', '--job', 'ipad-owner-receipt', '--',
        *command], capture_output=True, text=True)
    log = result.stdout + result.stderr
    (ROOT / f'.audit/ipad-owner-receipt-{suite}-result.log').write_text(log)
    print(log, end='')
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == digest for p, digest in hashes.items())
    raise SystemExit(result.returncode)

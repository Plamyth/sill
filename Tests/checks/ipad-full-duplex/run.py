"""Narrow independent Mini RAM checks, not source-guard task transfer or device acceptance."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

here = Path(__file__).resolve().parent
root = here.parents[2]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
if (output / 'result.json').exists(): raise SystemExit('reconcile existing attempt before retry')
paths = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
paths += [root / 'iOSClient' / name for name in ['IPadMicrophoneCapture.swift', 'IPadMicrophonePCM.swift',
    'IPadMicrophonePolicy.swift', 'IPadAudioRoutePolicy.swift', 'IPadRemoteAudioController.swift',
    'StreamClient+AudioRoutes.swift', 'StreamClient+Audio.swift', 'StreamClient.swift', 'StreamScreen.swift',
    'IPadAudioRouteChooser.swift', 'ContentView.swift', 'StreamClient+Microphone.swift', 'RemoteAudioPlayer.swift']]
paths += [root / folder / name for folder, names in {
    'iOSClient/Tests/audio-routes': ['main.swift', 'Standins.swift'],
    'Tests/checks/iPad-remote-audio': ['main.swift', 'fixture.py', 'player-fixture.py', 'player-standins.swift'],
    'Tests/checks': ['swift_platform.py']}.items() for name in names]
paths += [here / 'remote.py', Path(__file__).resolve()]
sha = lambda data: hashlib.sha256(data).hexdigest()
original = {str(path.relative_to(root)): sha(path.read_bytes()) for path in paths}
source = {str(path.relative_to(root)): path.read_bytes() for path in paths}
payload = json.dumps({'hashes': {name: sha(data) for name, data in source.items()},
    'source': {name: base64.b64encode(data).decode() for name, data in source.items()}}).encode()
command = ['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', (here / 'remote.py').read_text()]
child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
log, _ = child.communicate(payload, timeout=400)
(output / 'run.log').write_bytes(log)
lines = log.decode(errors='replace').splitlines()
results = [line[len('RESULT_JSON '):] for line in lines if line.startswith('RESULT_JSON ')]
record = {'inputSHA256': sha(payload), 'senderReceiverMatch': ('INPUT_SHA256 ' + sha(payload)) in lines,
    'sourceSHA256': original, 'sourceUnchanged': all(sha((root / name).read_bytes()) == digest for name, digest in original.items()),
    'exitCode': child.returncode, 'transportReaped': child.poll() is not None,
    'remote': json.loads(results[-1]) if results else None}
(output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
if record['remote']:
    for check in record['remote'].get('checks', []):
        print(check['name'], check['exitCode'], check['log'][-6500:])
    if record['remote'].get('error'): print(record['remote']['error'])
else: print(log.decode(errors='replace')[-6000:])
print(json.dumps({key: record[key] for key in ['inputSHA256', 'exitCode', 'sourceUnchanged', 'senderReceiverMatch']}))
sys.exit(child.returncode if record['sourceUnchanged'] and record['senderReceiverMatch'] and results else 2)

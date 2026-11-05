"""Pure production contract checks on Mini. No device, media, Host/Core or volume operations."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
suites = ['vision-provider-call'] if '--provider-only' in sys.argv else [
    'vision-provider-call', 'vision-microphone-permission', 'vision-audio-privacy']
if '--remote' in sys.argv:
    with tempfile.TemporaryDirectory(prefix='vision-voice-checks-') as scratch:
        def run(name):
            output = Path(scratch) / name
            command = ['python3', '-B', str(root / 'Tests/checks' / name / 'run.py')]
            if name != 'vision-provider-call':
                command += [str(root), str(output)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            logs = {p.name: p.read_text() for p in output.glob('*.log')}
            return dict(name=name, exitCode=result.returncode, stdout=result.stdout,
                        stderr=result.stderr, logs=logs)
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(run, suites))
        print('CHECK_RESULTS ' + json.dumps(results), flush=True)
        code = int(any(r['exitCode'] for r in results))
    print('CHECK_SCRATCH_REMOVED ' + str(not Path(scratch).exists()).lower(), flush=True)
    sys.exit(code)

output = Path(sys.argv[1]).resolve()
paths = list((root / 'Sources/StreamProtocol').glob('*.swift'))
for suite in ['vision-provider-call', 'vision-microphone-permission', 'vision-audio-privacy']:
    paths += list((root / 'Tests/checks' / suite).glob('*.*'))
paths += [root / p for p in [
    'visionOSClient/VisionProviderCall.swift', 'visionOSClient/VisionAudioForwarding.swift',
    'visionOSClient/VisionRemoteAudioIntent.swift', 'visionOSClient/VisionRemoteAudioAuthority.swift',
    'visionOSClient/StreamClient+VisionMicrophone.swift', 'iOSClient/IPadMicrophonePolicy.swift',
    'iOSClient/StreamClient.swift', 'Sources/SillHost/StreamServer.swift', 'Sources/SillHost/StreamCoordinator.swift']]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
with tempfile.TemporaryDirectory(prefix='vision-voice-input-') as staging:
    for path in paths:
        destination = Path(staging) / path.relative_to(root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', staging,
               '--owner', os.environ.get('CODEX_THREAD_ID', 'vision-native-voice-20261105'),
               '--job', 'vision-native-stop-recovery-contract', '--',
               'python3', '-B', 'Tests/checks/vision-provider-call/mini.py', '--remote']
    if '--provider-only' in sys.argv:
        command.append('--provider-only')
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
record = dict(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr,
              sourceSHA256=before, sourceUnchanged=all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in before.items()),
              deviceCalls=0, mediaCalls=0, hostCoreConnections=0,
              scope='Independent pure-contract execution, not source-guard task transfer or SDK acceptance')
output.write_text(json.dumps(record, indent=2) + '\n')
print(result.stdout)
print(result.stderr)
print('RECEIPT ' + str(output))
sys.exit(result.returncode)

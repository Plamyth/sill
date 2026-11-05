"""Run only synthetic source checks, with bounded task-scoped Mini input and cleanup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--staged', action='store_true')
parser.add_argument('--sdk-only', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
fixture = root / 'Tests/checks/native-realtime-media'
sha = lambda raw: hashlib.sha256(raw).hexdigest()

def inputs():
    paths = [root / 'Sources/SillHost' / name for name in ['NativeRealtimeMedia.swift', 'NativeRealtimePCM.swift',
             'LocalAudioRelay.swift', 'ProviderCallBridge.swift'] if (root / 'Sources/SillHost' / name).exists()]
    paths += list((root / 'Sources/StreamProtocol').glob('*.swift'))
    for folder in ['native-realtime-media', 'provider-call-bridge', 'native-realtime-pcm']:
        suffixes = ['.swift', '.py'] + (['.json'] if folder == 'provider-call-bridge' else [])
        paths += [p for p in (root / 'Tests/checks' / folder).iterdir()
                  if p.is_file() and p.suffix in suffixes]
    return sorted(set(paths))

if args.staged or args.sdk_only:
    paths = inputs()
    before = {str(p.relative_to(root)): sha(p.read_bytes()) for p in paths}
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='native-media-build-', dir=fixture) as directory:
        out = Path(directory)
        swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill', '-sdk', sdk,
                 '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]
        def run(command):
            subprocess.run(command, check=True, timeout=240)
        run(swift + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
                     *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
                     '-o', str(out / 'libStreamProtocol.dylib'),
                     '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')])
        bridge = (root / 'Sources/SillHost/ProviderCallBridge.swift').read_text()
        support = 'import Foundation\nimport CryptoKit\nimport StreamProtocol\n'
        support += bridge[bridge.index('private struct ProviderKey:'):bridge.index('func providerSameSnapshot')]
        support += bridge[bridge.index('enum ProviderCallFailure:'):bridge.index('enum ProviderCallTarget:')]
        support += bridge[bridge.index('struct CodexRealtimeTarget:'):bridge.index('struct WebGuestTarget:')]
        relay = (root / 'Sources/SillHost/LocalAudioRelay.swift').read_text()
        support += relay[relay.index('enum LocalAudioRelayJSON {'):relay.index('@MainActor')]
        (out / 'Support.swift').write_text(support)
        source = root / 'Sources/SillHost/NativeRealtimeMedia.swift'
        files = [out / 'Support.swift'] + ([source] if source.exists() else [])
        common = swift + ['-I', str(out), '-L', str(out), '-lStreamProtocol']
        run(common + ['-warnings-as-errors', '-typecheck', *map(str, files), str(fixture / 'main.swift')])
        if not args.sdk_only:
            run(common + [*map(str, files), str(fixture / 'main.swift'), '-o', str(out / 'checks')])
            subprocess.run([str(out / 'checks')], check=True, timeout=120,
                           env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)})
            run(['python3', '-B', str(root / 'Tests/checks/provider-call-bridge/run.py')])
            run(swift + [str(root / 'Sources/SillHost/NativeRealtimePCM.swift'),
                         str(root / 'Tests/checks/native-realtime-pcm/main.swift'), '-o', str(out / 'pcm')])
            run([str(out / 'pcm')])
    after = {str(p.relative_to(root)): sha(p.read_bytes()) for p in paths}
    assert before == after
    print('NATIVE_MEDIA_SDK ' + json.dumps(dict(sdk=sdk, sourceHashesBefore=before, sourceHashesAfter=after,
        temporaryBuildRemoved=not out.exists(), actualCoreConnected=False, actualAudioAccepted=False)))
    sys.exit(0)

routed = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'CCR-Vision']))
assert Path(routed['path']) / 'host-native-media-codec-20261105' == root
before = {str(p.relative_to(root)): sha(p.read_bytes()) for p in inputs()}
with tempfile.TemporaryDirectory(prefix='mini-input-', dir=fixture) as directory:
    stage = Path(directory)
    for name in before:
        destination = stage / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((root / name).read_bytes())
    result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
        '--owner', os.environ['CODEX_THREAD_ID'], '--job', 'host-native-media-codec-20261105', '--',
        'python3', '-B', 'Tests/checks/native-realtime-media/run-mini.py', '--staged'], capture_output=True, text=True)
after = {name: sha((root / name).read_bytes()) for name in before}
assert before == after
records = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{"receipt":')]
remote = records[-1] if records else None
proofs = [json.loads(line.removeprefix('NATIVE_MEDIA_SDK ')) for line in result.stdout.splitlines()
          if line.startswith('NATIVE_MEDIA_SDK ')]
proof = proofs[-1] if proofs else None
run_id = len(list(fixture.glob('validation-*.log'))) + 1
log = fixture / f'validation-{run_id:02d}.log'
log.write_text(result.stdout + result.stderr)
record = dict(exitCode=result.returncode, sourceHashesBefore=before, sourceHashesAfter=after, remoteProof=proof,
              miniReceipt=remote, temporaryInputRemoved=not stage.exists(), actualCoreConnected=False,
              actualAudioAccepted=False, actualHostChanges=0, deviceCalls=0, rootLedgerWrites=0)
(fixture / f'validation-{run_id:02d}.json').write_text(json.dumps(record, indent=2) + '\n')
for line in result.stdout.splitlines():
    if line.startswith('NATIVE_MEDIA_SDK '):
        proof = json.loads(line.removeprefix('NATIVE_MEDIA_SDK '))
        print(json.dumps(dict(remoteSHAStable=proof['sourceHashesBefore'] == proof['sourceHashesAfter'],
                              temporaryBuildRemoved=proof['temporaryBuildRemoved'])))
    else:
        print(line)
if result.returncode:
    print(result.stderr[-5500:], file=sys.stderr)
print(json.dumps(dict(log=str(log), validation=str(fixture / f'validation-{run_id:02d}.json'),
                      exitCode=result.returncode, cleanupVerified=bool(remote and remote['cleanup_verified']))))
assert remote and remote['cleanup_verified']
if result.returncode == 0:
    assert proof and proof['sourceHashesBefore'] == before and proof['sourceHashesAfter'] == after
sys.exit(result.returncode)

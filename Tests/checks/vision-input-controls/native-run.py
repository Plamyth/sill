"""Compile existing production-extracted gesture fixtures with inert I/O on Mini."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from extract import fixture
from run import callback_mutants, execute
import run as runner

ROOT = Path(__file__).resolve().parents[3]
received = json.loads((ROOT / 'received-source-sha256.json').read_text())
assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == digest for p, digest in received.items())
print('RECEIVED_SOURCE_HASHES_MATCHED ' + str(len(received)), flush=True)
files, extraction = fixture()
deadline = time.monotonic() + 600
commands = []
with tempfile.TemporaryDirectory(prefix='native-checks-', dir=ROOT) as folder:
    out = Path(folder)
    generated = out / 'generated'
    for name, contents in files.items():
        p = generated / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(contents)
    env = dict(os.environ)
    xcode = Path('/Applications/Xcode.app/Contents/Developer')
    developer = str(xcode) if xcode.is_dir() else subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip()
    runner.DEVELOPER_DIR = developer
    print('PURE_TEST_DEVELOPER_DIR ' + developer, flush=True)
    base = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'sill', '-module-cache-path', str(out / 'cache')]
    def run(command, label, witness=None):
        log, result = execute(command, timeout=150, output=out, deadline=deadline)
        commands.append({'label': label, 'exitCode': result['exitCode'], 'cleanupVerified': result['processGroup']['verified'], 'reaped': result['reaped']})
        assert result['processGroup']['verified'] and result['reaped'], label + ' child cleanup unverified'
        if witness:
            assert result['exitCode'] != 0 and 'Precondition failed: ' + witness in log, label + '\n' + log[-5000:]
        elif result['exitCode']:
            print(label, log[-12000:], flush=True)
            raise SystemExit(result['exitCode'])
        return log
    groups = [('Network', [generated / 'Network.swift']), ('SwiftUI', [generated / 'SwiftUI.swift']),
              ('StreamProtocol', sorted((generated / 'Sources/StreamProtocol').glob('*.swift')))]
    for name, sources in groups:
        run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name] + list(map(str, sources)) + ['-emit-module-path', str(out / (name + '.swiftmodule')), '-o', str(out / (name + '.o'))], 'compile-' + name)
    names = ['Client.swift', 'VisionWindowLease.swift', 'visionOSClient/VisionDisplaySelection.swift', 'SpatialAdapter.swift', 'SpatialCallbacks.swift', 'LifecycleTests.swift', 'ScrollMomentum.swift', 'MomentumDriver.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionAudioGain.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionTextDraft.swift', 'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionRemoteKey.swift', 'Tests/checks/vision-input-controls/SourceInputFence.swift', 'main.swift']
    objects = [str(out / (name + '.o')) for name, _ in groups]
    run(base + ['-I', str(out)] + [str(generated / name) for name in names] + objects + ['-o', str(out / 'checks')], 'compile-controls')
    log = run([str(out / 'checks')], 'runtime-controls')
    print('\n'.join(line for line in log.splitlines() if 'ASSERTIONS' in line or line.startswith('native temporal')), flush=True)
    pointer = ['iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputFence.swift', 'visionOSClient/VisionTransition.swift', 'Tests/vision-pointer/main.swift']
    run(base + ['-I', str(out)] + [str(generated / name) for name in pointer] + [str(out / 'StreamProtocol.o'), '-o', str(out / 'pointer')], 'compile-pointer')
    pointer_log = run([str(out / 'pointer')], 'runtime-pointer')
    print(pointer_log[-1000:], flush=True)
    mutants = []
    for name, (source, witness) in callback_mutants(files['SpatialCallbacks.swift']).items():
        path = out / ('mutant-' + name + '.swift'); path.write_text(source)
        executable = out / ('mutant-' + name)
        sources = [path if n == 'SpatialCallbacks.swift' else generated / n for n in names]
        run(base + ['-I', str(out)] + list(map(str, sources)) + objects + ['-o', str(executable)], 'compile-mutant-' + name)
        run([str(executable)], 'runtime-mutant-' + name, witness)
        mutants.append(name)
    assert all((generated / name).read_text() == source for name, source in files.items())
    print('NATIVE_RESULT ' + json.dumps({'assertions': int(re.search(r'RESULT_ASSERTIONS (\d+)', log)[1]), 'pointerAssertions': int(re.search(r'Vision input: (\d+) behavioral checks', pointer_log)[1]), 'mutantsCaught': mutants, 'extractionSHA256': extraction, 'generatedHashesMatched': True, 'receivedHashesMatched': True, 'pureTestDeveloperDir': developer, 'commands': commands, 'externalEffects': 0}), flush=True)

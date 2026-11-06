"""공통 Craft action의 순수 once 모델 검사. 제품 연결·기기·음성 효과 없음."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
if '.onLongPressGesture(minimumDuration: VisionConfiguredCraftAction.holdDuration)' not in view:
    raise SystemExit('FAIL 음성 주 동작에 500ms longPress가 없습니다. 짧은 누름과 통화 ACK 경로가 남아 있습니다.')
if '--static-only' in sys.argv:
    if 'configuredExecutor.begin(' not in view or 'configuredExecutor.cancel(operationId:' not in view:
        raise SystemExit('FAIL prepare/invoke/cancelPreparation의 제품 executor가 UI에 연결되지 않았습니다.')
    print('PASS 500ms 전용 제스처 연결')
    raise SystemExit(0)

paths = [root / p for p in ['visionOSClient/SillVisionApp.swift',
    'iOSClient/StreamClient.swift',
    'visionOSClient/VisionConfiguredCraftAction.swift', 'visionOSClient/VisionRemoteAudioIntent.swift',
    'visionOSClient/VisionRemoteAudioAuthority.swift',
    'visionOSClient/VisionProviderCall.swift', 'visionOSClient/VisionAudioForwarding.swift',
    'Tests/checks/vision-audio-privacy/adapter.swift',
    'Tests/checks/vision-configured-craft-action/store-adapter.swift',
    'Tests/checks/vision-configured-craft-action/store-main.swift',
    'Tests/checks/vision-configured-craft-action/run.py', 'Tests/checks/vision-configured-craft-action/main.swift']]
paths += sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
if '--mini' in sys.argv:
    output = Path(sys.argv[sys.argv.index('--mini') + 1]).resolve()
    with tempfile.TemporaryDirectory(prefix='vision-craft-input-') as staging:
        for path in paths:
            destination = Path(staging) / path.relative_to(root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', staging,
            '--owner', os.environ['CODEX_THREAD_ID'], '--job', 'vision-configured-craft-action-20261106', '--',
            'python3', '-B', 'Tests/checks/vision-configured-craft-action/run.py'], capture_output=True, text=True, timeout=180)
    cleanup = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{') and 'cleanup_verified' in line]
    unchanged = all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in before.items())
    record = dict(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr, sourceSHA256=before,
                  sourceUnchanged=unchanged, cleanupVerified=bool(cleanup and cleanup[-1]['cleanup_verified']),
                  actualHostCoreDeviceMediaActions=0, scope='독립 순수 상태 검사. task transfer·제품 route·실기 수용은 아님.')
    output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(result.stdout + result.stderr)
    raise SystemExit(0 if result.returncode == 0 and unchanged and record['cleanupVerified'] else 1)

with tempfile.TemporaryDirectory(prefix='vision-craft-check-') as temporary:
    out = Path(temporary)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache'), '-module-name', 'StreamProtocol', '-emit-module', '-emit-library', *[str(p) for p in sorted((root / 'Sources/StreamProtocol').glob('*.swift'))], '-o', str(out / 'libStreamProtocol.dylib')], check=True)
    result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache'), '-I', str(out), '-L', str(out), '-lStreamProtocol',
        str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
        str(root / 'visionOSClient/VisionConfiguredCraftAction.swift'),
        str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'),
        str(Path(__file__).with_name('main.swift')), '-o', str(out / 'checks')], check=True)
    subprocess.run([str(out / 'checks')], check=True, env=dict(os.environ, DYLD_LIBRARY_PATH=str(out)))
    source = (root / 'visionOSClient/VisionRemoteAudioAuthority.swift').read_text()
    store = source[source.index('final class VisionRemoteAudioStore {'):source.rindex('\n#endif')]
    (out / 'Store.swift').write_text('import Foundation\nimport StreamProtocol\n' + store)
    client = (root / 'iOSClient/StreamClient.swift').read_text()
    start = client.index('    func receiveVisionAudioCatalogAcknowledgement(')
    end = client.index('    func updateVisionMacAudioRoutes(', start)
    (out / 'CatalogTransport.swift').write_text('import Foundation\nimport StreamProtocol\nextension StreamClient {\n' + client[start:end].replace('VisionRemoteAudioStore.shared', 'store') + '}\n')
    shutil.copyfile(Path(__file__).with_name('store-main.swift'), out / 'main.swift')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache'),
        '-I', str(out), '-L', str(out), '-lStreamProtocol',
        *[str(root / 'visionOSClient' / (name + '.swift')) for name in
          ['VisionRemoteAudioIntent', 'VisionRemoteAudioAuthority', 'VisionConfiguredCraftAction', 'VisionProviderCall', 'VisionAudioForwarding']],
        str(out / 'Store.swift'), str(root / 'Tests/checks/vision-audio-privacy/adapter.swift'),
        str(Path(__file__).with_name('store-adapter.swift')), str(out / 'CatalogTransport.swift'),
        str(out / 'main.swift'), '-o', str(out / 'store-checks')], check=True)
    subprocess.run([str(out / 'store-checks')], check=True, env=dict(os.environ, DYLD_LIBRARY_PATH=str(out)))
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())

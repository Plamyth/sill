#!/usr/bin/env python3
"""격리 Store 동작과 전체 Canvas iOS SDK 타입 검사. 앱이나 서비스를 실행하지 않는다."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-ipad'], text=True))
output = Path(route['path']) / 'node-resize-20261024'
if sys.argv[1:] and sys.argv[1:] != [str(output)]:
    raise SystemExit('storage-route가 지정한 출력 경로만 사용합니다.')
output.mkdir(parents=True, exist_ok=True)
attempt = Path(tempfile.mkdtemp(prefix='verification-', dir=output))
developer = '/Applications/Xcode.app/Contents/Developer'
compile_home = attempt / 'compile-home'
compile_home.mkdir()
env = dict(os.environ, DEVELOPER_DIR=developer, HOME=str(compile_home), CFFIXED_USER_HOME=str(compile_home))
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
store = root / 'iOSClient/CanvasBridge/CanvasStore.swift'
workspace = root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift'
plist = root / 'Tests/checks/ink-undo/Info.plist'
suites = [('node-resize', here / 'NodeResizeChecks.swift'),
          ('store-regression', root / 'Tests/checks/pele-live/StoreChecks.swift'),
          ('endpoint-regression', root / 'Tests/checks/pele-live/EndpointChecks.swift')]
sources = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift'))
sources += [root / ('iOSClient/' + name + '.swift') for name in
            ['IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator']]
sources += [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
module = root / 'Sources/StreamProtocol/TestDestinations.swift'
inputs = sorted(set(sources + [module, plist, Path(__file__).resolve()] + [p for _, p in suites]))
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
results = []


def run(name, command, run_env=None, timeout=240):
    command = list(map(str, command))
    result = subprocess.run(command, env=run_env or env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    (attempt / (name + '.log')).write_text(result.stdout)
    print(name, result.returncode, flush=True)
    if result.stdout:
        print(result.stdout[-6000:], end='', flush=True)
    results.append(dict(name=name, command=command, exitCode=result.returncode))
    if result.returncode:
        raise RuntimeError(name)


status = 0
try:
    mac = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    ios = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
    for sdk in ['macosx', 'iphoneos']:
        version = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], env=env, text=True).strip()
        if version != '27.0':
            raise RuntimeError(f'필수 SDK27이 아닙니다: {sdk} {version}')
    # 기존 pele-live runner와 같은 production Model/Store + macOS PencilKit 검사 경로다.
    base = ['xcrun', 'swiftc', '-sdk', mac, '-target', 'arm64e-apple-macos27.0', '-swift-version', '5',
            '-module-cache-path', attempt / 'mac-modules']
    for name, suite in suites:
        folder = attempt / name
        folder.mkdir()
        home = folder / 'home'
        home.mkdir()
        test_env = dict(env, HOME=str(home), CFFIXED_USER_HOME=str(home), PELE_OUTPUT=str(folder))
        binary = folder / 'check'
        run(name + '-compile', base + ['-parse-as-library', model, store, suite,
            '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
            '-Xlinker', plist, '-o', binary])
        run(name + '-run', [binary], test_env, 60)
    iosdir = attempt / 'ios'
    iosdir.mkdir()
    iosbase = ['xcrun', 'swiftc', '-sdk', ios, '-target', 'arm64-apple-ios27.0', '-swift-version', '5',
               '-module-cache-path', attempt / 'ios-modules']
    run('ios-module', iosbase + ['-emit-module', '-module-name', 'StreamProtocol', module,
        '-emit-module-path', iosdir / 'StreamProtocol.swiftmodule'])
    run('all-canvas-ios-typecheck', iosbase + ['-parse-as-library', '-I', iosdir, '-typecheck', *sources])
    ui = workspace.read_text().split('private struct CanvasNodeResizeHandle: View {', 1)[1].split(
        'private struct CanvasEndpointHandle: View {', 1)[0]
    assert 'coordinateSpace:.named("canvasScene")' in ui
    assert 'x:value.translation.width,y:value.translation.height' in ui
    assert 'value.translation.width/store.zoom' not in ui
    assert '.frame(width:44 / store.zoom,height:44 / store.zoom)' in ui
    assert '.accessibilityLabel("선택한 요소 크기 조절")' in ui
    assert '.onDisappear' in ui and 'cancelNodeResize(owner:owner)' in ui
    assert 'store.nodeResizeDrag == nil' in workspace.read_text().split('private struct NodeTile: View {', 1)[1]
    results.append(dict(name='resize-ui-wiring-static', exitCode=0,
                        scope='좌표계·44pt·한국어·취소·본문 제스처 분리의 정적 연결 검사이며 실제 UI 수용은 아님'))
    run('git-diff-check', ['git', '-C', root, 'diff', '--check'])
except Exception as error:
    print(str(error), flush=True)
    results.append(dict(name='failure', error=str(error), exitCode=1))
    status = 1
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
if hashes != after:
    status = 1
receipt = dict(results=results, inputHashes=hashes, inputsUnchanged=hashes == after,
    head=subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip(),
    developerDirectory=developer, output=str(attempt), exitCode=status,
    host='MacBook', realVaultTouched=False, deviceExecuted=False, appExecuted=False,
    browserExecuted=False, sharedHostChanged=False, externalEffects=0,
    remaining='실제 Pencil/터치·제스처 중단·44pt hit test·zoom 실화면·설치·개인 Obsidian 왕복은 미검증')
(attempt / 'result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
(output / 'latest-result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
print(attempt, flush=True)
sys.exit(status)

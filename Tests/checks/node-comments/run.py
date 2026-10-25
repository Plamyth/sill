#!/usr/bin/env python3
"""순수 모델은 Mini, PencilKit 저장 검사와 iOS 타입 검사는 맥북에서 격리 실행한다."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'ccr-ipad'], text=True))
output = Path(route['path']) / 'ipad-node-comments-20261026'
output.mkdir(parents=True, exist_ok=True)
attempt = Path(tempfile.mkdtemp(prefix='verification-', dir=output))
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
store = root / 'iOSClient/CanvasBridge/CanvasStore.swift'
plist = root / 'Tests/checks/ink-undo/Info.plist'
sources = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift'))
sources += [root / ('iOSClient/' + name + '.swift') for name in
            ['IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator']]
sources += [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
module = root / 'Sources/StreamProtocol/TestDestinations.swift'
pure_suites = [here / 'main.swift', root / 'Tests/checks/ipad-canvas-revisions/main.swift',
               root / 'Tests/checks/canvas-hierarchy/main.swift']
store_suites = [here / 'StoreChecks.swift', root / 'Tests/checks/node-rotation/NodeRotationChecks.swift',
                root / 'Tests/checks/node-resize/NodeResizeChecks.swift',
                root / 'Tests/checks/pele-live/StoreChecks.swift',
                root / 'Tests/checks/pele-live/EndpointChecks.swift']
inputs = sorted(set(sources + [module, plist, Path(__file__).resolve()] + pure_suites + store_suites))
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
results = []
compile_home = attempt / 'compile-home'
compile_home.mkdir()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           HOME=str(compile_home), CFFIXED_USER_HOME=str(compile_home))

def run(name, command, run_env=None, timeout=300):
    command = list(map(str, command))
    result = subprocess.run(command, env=run_env or env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    (attempt / (name + '.log')).write_text(result.stdout)
    print(name, result.returncode, flush=True)
    if result.stdout:
        print(result.stdout[-6500:], end='', flush=True)
    results.append(dict(name=name, command=command, exitCode=result.returncode))
    if result.returncode:
        raise RuntimeError(name)

status = 0
stage = attempt / 'mini-input'
try:
    stage.mkdir()
    shutil.copyfile(model, stage / 'CanvasModel.swift')
    suite_names = []
    for suite in pure_suites:
        folder = stage / suite.parent.name
        folder.mkdir()
        shutil.copyfile(suite, folder / 'main.swift')
        suite_names.append(suite.parent.name)
    remote = '''import hashlib,json,pathlib,subprocess\nroot=pathlib.Path.cwd()\nfiles=list(root.rglob('*.swift'))\ndef hashes(): return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}\nbefore=hashes()\nfor name in NAMES:\n command=['xcrun','swiftc','-swift-version','5','-module-cache-path','modules','CanvasModel.swift',name+'/main.swift','-o',name+'/check']\n subprocess.run(command,check=True)\n subprocess.run([str(root/name/'check')],check=True)\nassert hashes()==before\nprint(json.dumps({'host':'Mac mini','inputHashes':before,'inputsUnchanged':True},ensure_ascii=False))\n'''.replace('NAMES', repr(suite_names))
    (stage / 'run.py').write_text(remote)
    run('mini-pure-model', ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run',
        '--source', stage, '--owner', os.environ.get('CODEX_THREAD_ID', 'ipad-node-comments-20261026'),
        '--job', 'ipad-node-comments-20261026', '--', 'python3', 'run.py'], timeout=600)
    mini_log = (attempt / 'mini-pure-model.log').read_text()
    receipt = json.loads(mini_log.strip().splitlines()[-1])
    if receipt.get('cleanup_verified') is not True:
        raise RuntimeError('Mini 한시적 입력 정리 확인 실패')
    (attempt / 'mini-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    mac = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    ios = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
    base = ['xcrun', 'swiftc', '-sdk', mac, '-target', 'arm64e-apple-macos27.0', '-swift-version', '5',
            '-module-cache-path', attempt / 'mac-modules']
    for index, suite in enumerate(store_suites):
        name = f'store-{index}-{suite.parent.name}'
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
    workspace = (root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift').read_text()
    renderer = (root / 'iOSClient/CanvasBridge/SceneRenderer.swift').read_text()
    assert 'pendingCommentEdit' in workspace.split('.sheet(isPresented:$inspectorOpen,onDismiss:',1)[1].split('NavigationStack',1)[0]
    sheet = workspace.split('private var commentSheet:',1)[1].split('private var proposalSheet:',1)[0]
    assert 'VaultMarkdownEditor' in sheet and 'inputBusy:$store.commentInputBusy' in sheet
    assert '.interactiveDismissDisabled(store.commentInputBusy)' in sheet and '.disabled(store.commentInputBusy)' in sheet
    assert 'let annotationFrames = displayed.annotationFrames' in workspace and 'scene.annotationFrames' in renderer
    assert '.lineLimit(3)' in workspace and 'cg.clip(to:frame)' in renderer
    assert 'canvasEditComment' in workspace and '.frame(minHeight:44)' in workspace
    results.append(dict(name='comment-ui-wiring-static', exitCode=0,
        scope='기존 입력기·조합 중 닫기 금지·검사기 닫힘 순서·공통 배치의 정적 연결이며 실제 화면 수용은 아님'))
    run('git-diff-check', ['git', '-C', root, 'diff', '--check'])
except Exception as error:
    print(str(error), flush=True)
    results.append(dict(name='failure', error=str(error), exitCode=1))
    status = 1
finally:
    if stage.exists():
        shutil.rmtree(stage)
after = hashes()
if before != after:
    status = 1
receipt = dict(results=results, inputHashes=before, afterHashes=after, inputsUnchanged=before == after,
    head=subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip(),
    output=str(attempt), exitCode=status, deviceExecuted=False, appExecuted=False,
    realVaultTouched=False, sharedHostChanged=False, externalEffects=0,
    remaining='실제 Pencil·렌더링 픽셀·열린 iPad 화면·설치·실사용 vault·liveRelay 왕복은 이번 검증 범위 밖')
(attempt / 'result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
print(attempt, flush=True)
sys.exit(status)

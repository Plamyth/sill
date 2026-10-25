#!/usr/bin/env python3
"""제품 Store 및 화면 없는 실제 Catalyst canvas의 P2 회귀 검사."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('검증된 외장 검사 경로가 필요합니다.')
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'iOSClient/CanvasBridge/CanvasModel.swift', root / 'iOSClient/CanvasBridge/CanvasStore.swift']
if mode == 'projection':
    sources += [Path(__file__).with_name('ProjectionIntegrityChecks.swift')]
elif mode == 'undo':
    sources += [root / 'iOSClient/CanvasBridge/PencilCanvas.swift', root / 'iOSClient/CanvasBridge/SceneRenderer.swift',
                root / 'Tests/checks/ink-undo/RejectedDrawingChecks.swift']
elif mode == 'undo-full':
    sources += [root / 'iOSClient/CanvasBridge/PencilCanvas.swift', root / 'iOSClient/CanvasBridge/SceneRenderer.swift',
                root / 'Tests/checks/ink-undo/InkUndoChecks.swift', root / 'Tests/checks/ink-undo/main.swift']
else:
    raise SystemExit('projection, undo, undo-full 중 하나를 지정하세요.')
plist = root / 'Tests/checks/ink-undo/Info.plist'
inputs = sources + [plist, Path(__file__)]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
target = 'arm64e-apple-macos27.0' if mode == 'projection' else 'arm64-apple-ios27.0-macabi'
command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', target, '-swift-version', '5', '-parse-as-library',
           '-module-cache-path', str(output.parent / (mode + '-modules'))]
if mode != 'projection':
    command += ['-F', sdk + '/System/iOSSupport/System/Library/Frameworks',
                '-I', sdk + '/System/iOSSupport/usr/include', '-L', sdk + '/System/iOSSupport/usr/lib']
command += [*map(str, sources), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
            '-Xlinker', '__info_plist', '-Xlinker', str(plist), '-o', str(output / 'check')]

def run(command, name, timeout):
    child = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
    (output / name).write_text(log)
    print(log, end='', flush=True)
    return child.returncode

compile_code = run(command, 'compile.log', 240)
runtime_code = None
if compile_code == 0:
    home = output / 'home'
    home.mkdir(exist_ok=True)
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
    runtime_code = run([str(output / 'check')], 'runtime.log', 90)
unchanged = all(hashlib.sha256(p.read_bytes()).hexdigest() == hashes[str(p.relative_to(root))] for p in inputs)
result = 0 if compile_code == 0 and runtime_code == 0 and unchanged else 1
(output / 'result.json').write_text(json.dumps(dict(sourceHashes=hashes, sourceUnchanged=unchanged,
    compileExit=compile_code, runtimeExit=runtime_code, command=command, exitCode=result,
    actualPKCanvasView=mode != 'projection' and compile_code == 0 and runtime_code is not None,
    productionCoordinator=mode != 'projection' and compile_code == 0 and runtime_code is not None,
    controlledNativeRegistrations=mode != 'projection', hardwarePencil=False, UIUsed=False,
    signed=False, installed=False, externalNetworkRequests=0), indent=2) + '\n')
sys.exit(result)

#!/usr/bin/env python3
"""Native Store/PencilKit checks with isolated preferences; no app or device launch."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-ipad'], text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(route['path']).resolve()) or output.exists():
    raise SystemExit('Use a fresh output directory beneath verified storage-route path')
output.mkdir(parents=True)
home, tmp = output / 'home', output / 'tmp'
home.mkdir()
tmp.mkdir()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(tmp) + '/')
model, store, pencil, workspace, renderer = [root / 'iOSClient/CanvasBridge' / name for name in
    ['CanvasModel.swift', 'CanvasStore.swift', 'PencilCanvas.swift', 'CanvasWorkspace.swift', 'SceneRenderer.swift']]
plist = root / 'Tests/checks/ink-visibility/Info.plist'
inputs = [model, store, pencil, workspace, renderer, here / 'main.swift', Path(__file__), plist]


def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


before = hashes()
results = []


def run(command, name, timeout=240):
    child = subprocess.Popen(list(map(str, command)), cwd=root, env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
    try:
        os.killpg(child.pid, 0)
        gone = False
    except ProcessLookupError:
        gone = True
    if not gone:
        os.killpg(child.pid, signal.SIGKILL)
    (output / (name + '.log')).write_text(log)
    results.append(dict(name=name, command=list(map(str, command)), exitCode=child.returncode,
                        timedOut=timed_out, processGroupGone=gone, waited=child.poll() is not None))
    print(f'{name}: exit={child.returncode}', flush=True)
    if child.returncode != 0 or 'runtime' in name:
        print(log, end='', flush=True)
    return child.returncode


mac = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
ios = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
code = run(['xcrun', 'swiftc', '-sdk', mac, '-target', 'arm64e-apple-macos27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', output / 'mac-modules',
    model, store, here / 'main.swift', '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
    '-Xlinker', '__info_plist', '-Xlinker', plist, '-o', output / 'check'], 'native-compile')
status = code != 0
if code == 0:
    status |= run([output / 'check'], 'native-runtime', 90) != 0
    status |= run([output / 'check', '--restore'], 'reopen-runtime', 90) != 0
status |= run(['xcrun', 'swiftc', '-sdk', ios, '-target', 'arm64-apple-ios27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', output / 'ios-modules',
    '-typecheck', model, store, pencil, renderer], 'ios-pencil-typecheck') != 0
text = pencil.read_text()
menu = workspace.read_text()
wiring = {
    'nativeToolUsesSelectedSize': 'case .eraser: canvas.tool = store.eraserTool' in text,
    'previewUsesSelectedSize': 'previewLayer.lineWidth = store.mode == .eraser ? (store.eraserPreviewWidth ?? 4) : 4' in text,
    'strokePreviewHidden': 'previewLayer.isHidden = store.mode == .eraser && store.eraserPreviewWidth == nil' in text,
    'strokeHoverHidden': 'store.mode != .eraser || store.eraserPreviewWidth != nil' in text,
    'hoverUsesSelectedSize': 'let diameter: CGFloat = erasing ? (store.eraserPreviewWidth ?? 8) : 8' in text,
    'commonSceneZoom': '.scaleEffect(store.zoom,anchor:.topLeading)' in menu,
    'sixSizePicker': 'ForEach(CanvasEraserSize.allCases' in menu,
    'strokeSizeDisabled': '.disabled(store.eraserStyle != .partial)' in menu,
    'koreanUnitsAndAccessibility': all(s in menu for s in ['부분 지우개 크기 · CCR 포인트', 'canvasPartialEraserSize',
        '획 전체 지우기에서는 적용되지 않음', '확대 비율에 따라 표시 크기가 달라집니다.']),
    'nativeMenuTouchTarget': '.frame(minWidth:44,minHeight:44)' in menu,
}
status |= not all(wiring.values())
after = hashes()
status |= before != after or not all(r['processGroupGone'] and r['waited'] for r in results)
receipt = dict(worktree=str(root), head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    sourceHashes=before, sourceHashesAfter=after, sourceUnchanged=before == after,
    results=results, staticWiring=wiring, isolatedHome=str(home),
    deviceExecuted=False, appLaunched=False, liveSceneTouched=False, exitCode=int(bool(status)))
(output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
sys.exit(int(bool(status)))

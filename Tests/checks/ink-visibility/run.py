#!/usr/bin/env python3
"""Run the actual CanvasModel and CanvasStore with PencilKit in an isolated home."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-Sill-Obsidian'], text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(archive['path']).resolve()):
    raise SystemExit('Output must use the verified storage-route development archive')
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'iOSClient/CanvasBridge/CanvasModel.swift',
           root / 'iOSClient/CanvasBridge/CanvasStore.swift',
           Path(__file__).with_name('main.swift')]
inputs = sources + [Path(__file__), Path(__file__).with_name('Info.plist'),
    root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift',
    root / 'iOSClient/CanvasBridge/SceneRenderer.swift']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
home = output / 'home'
home.mkdir(exist_ok=True)
tmp = output / 'tmp'
tmp.mkdir(exist_ok=True)
tool_env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
                HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(tmp) + '/')
processes = []

def run(command, timeout):
    child = subprocess.Popen(command, env=tool_env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
    try:
        os.killpg(child.pid, 0)
        group_gone = False
    except ProcessLookupError:
        group_gone = True
    processes.append(dict(command=command, pid=child.pid, exitCode=child.returncode,
                          waited=child.poll() is not None, processGroupGone=group_gone,
                          timedOut=timed_out))
    if not group_gone:
        os.killpg(child.pid, signal.SIGKILL)
    return subprocess.CompletedProcess(command, child.returncode, log)

sdk_result = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], 30)
if sdk_result.returncode:
    raise SystemExit(sdk_result.stdout)
sdk = sdk_result.stdout.strip()
version = run(['xcrun', 'swiftc', '--version'], 30)
(output / 'compiler-version.log').write_text(version.stdout)
base = '2ebd263cf06843b92893ca3b1344ef271dc0a2d8'
renderer_path = 'iOSClient/CanvasBridge/SceneRenderer.swift'
original_renderer = subprocess.check_output(['git', 'show', f'{base}:{renderer_path}'], cwd=root, text=True)
renderer = (root / renderer_path).read_text()
native_prefix = renderer.split('                for stroke in scene.strokes {')[0]
native_unchanged = native_prefix == original_renderer.split('                for stroke in scene.strokes {')[0]
workspace = (root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift').read_text()
fallbacks_wired = all('for points in stroke.visiblePointSegments {' in s for s in [renderer, workspace])
if not native_unchanged or not fallbacks_wired:
    raise SystemExit('Native renderer preservation or fallback wiring check failed')
command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
           '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output / 'modules'),
           *map(str, sources), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
           '-Xlinker', '__info_plist', '-Xlinker', str(Path(__file__).with_name('Info.plist')),
           '-o', str(output / 'check')]
compile_result = run(command, 240)
(output / 'compile.log').write_text(compile_result.stdout)
print(compile_result.stdout, end='')
code = compile_result.returncode
if code == 0:
    result = run([str(output / 'check'), *sys.argv[2:]], 90)
    (output / 'runtime.log').write_text(result.stdout)
    print(result.stdout, end='')
    code = result.returncode
unchanged = all(hashlib.sha256(p.read_bytes()).hexdigest() == hashes[str(p.relative_to(root))] for p in inputs)
reaped = all(p['waited'] and p['processGroupGone'] for p in processes)
if not unchanged or not reaped:
    code = 1
interfaces = [Path(sdk) / 'System/Library/Frameworks/PencilKit.framework/Modules/PencilKit.swiftmodule/arm64e-apple-macos.swiftinterface',
    Path('/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/PencilKit.framework/Modules/PencilKit.swiftmodule/arm64e-apple-ios.swiftinterface')]
(output / 'result.json').write_text(json.dumps(dict(sourceHashes=hashes, sdk=sdk,
    compiler=version.stdout.strip(), command=command, exitCode=code, sourceUnchanged=unchanged,
    isolatedHome=str(home), childrenReaped=reaped, processes=processes,
    nativeRendererPrefixUnchanged=native_unchanged, fallbackWiringVerified=fallbacks_wired,
    sdkInterfaceSHA256={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in interfaces}), indent=2) + '\n')
sys.exit(code if code >= 0 else 1)

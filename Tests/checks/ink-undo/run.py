#!/usr/bin/env python3
"""Isolated native Foundation/PencilKit checks, plus iOS SDK compilation; no app launch."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-Sill-Obsidian'], text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(archive['path']).resolve()):
    raise SystemExit('Output must use the verified storage-route development archive')
output.mkdir(parents=True, exist_ok=True)
home, tmp = output / 'home', output / 'tmp'
home.mkdir(exist_ok=True)
tmp.mkdir(exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(tmp) + '/')
common = [root / 'iOSClient/CanvasBridge/CanvasModel.swift',
          root / 'iOSClient/CanvasBridge/CanvasStore.swift', here / 'InkUndoChecks.swift']
ios = [root / 'iOSClient/CanvasBridge/PencilCanvas.swift',
       root / 'iOSClient/CanvasBridge/SceneRenderer.swift']
inputs = common + ios + [here / 'main.swift', here / 'Info.plist', Path(__file__),
    root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
processes = []

def run(command, timeout, name):
    child = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
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
        gone = False
    except ProcessLookupError:
        gone = True
    if not gone:
        os.killpg(child.pid, signal.SIGKILL)
    processes.append(dict(command=command, exitCode=child.returncode, timedOut=timed_out,
                          processGroupGone=gone, waited=child.poll() is not None))
    (output / name).write_text(log)
    print(log, end='', flush=True)
    return child.returncode

sdk_root = Path('/Applications/Xcode.app/Contents/Developer/Platforms')
mac = sdk_root / 'MacOSX.platform/Developer/SDKs/MacOSX.sdk'
iphone = sdk_root / 'iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk'
code = run(['xcrun', 'swiftc', '-sdk', str(mac), '-target', 'arm64e-apple-macos27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output / 'mac-modules'),
    *map(str, common), str(here / 'main.swift'), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
    '-Xlinker', '__info_plist', '-Xlinker', str(here / 'Info.plist'), '-o', str(output / 'check')],
    240, 'mac-compile.log')
if code == 0:
    code = run([str(output / 'check')], 90, 'mac-runtime.log')
ios_code = run(['xcrun', 'swiftc', '-sdk', str(iphone), '-target', 'arm64-apple-ios27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output / 'ios-modules'),
    '-typecheck', *map(str, common + ios)], 240, 'ios-typecheck.log')
unchanged = all(hashlib.sha256(p.read_bytes()).hexdigest() == hashes[str(p.relative_to(root))] for p in inputs)
reaped = all(p['waited'] and p['processGroupGone'] for p in processes)
result = 0 if code == 0 and ios_code == 0 and unchanged and reaped else 1
(output / 'result.json').write_text(json.dumps(dict(sourceHashes=hashes, processes=processes,
    sourceUnchanged=unchanged, childrenReaped=reaped, macExit=code, iosSDKTypecheckExit=ios_code,
    isolatedHome=str(home), deviceExecuted=False, exitCode=result), indent=2) + '\n')
sys.exit(result)

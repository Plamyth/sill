#!/usr/bin/env python3
"""Isolated production model/store checks and Apple SDK compile; never use a device."""
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
    '--project', 'BT_CCR-ipad-hierarchyfold'], text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('Use the verified storage-route output directory')
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
store = root / 'iOSClient/CanvasBridge/CanvasStore.swift'
renderer = root / 'iOSClient/CanvasBridge/SceneRenderer.swift'
inputs = [*sorted((root / 'iOSClient/CanvasBridge').glob('*.swift')),
          *sorted(here.glob('*')), root / 'Tests/checks/canvas-hierarchy/main.swift',
          root / 'Tests/checks/ipad-canvas-revisions/main.swift']
inputs = [p for p in inputs if p.is_file()]


def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}


before = hashes()
results = []


def run(command, name, timeout=240, runtime_env=env):
    child = subprocess.Popen(list(map(str, command)), cwd=root, env=runtime_env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
    (output / (name + '.log')).write_text(log)
    results.append(dict(name=name, command=list(map(str, command)), exitCode=child.returncode,
                        timedOut=timed_out, log=str(output / (name + '.log'))))
    print(f'{name}: exit={child.returncode}', flush=True)
    if child.returncode != 0:
        print(log[-9000:], flush=True)
    elif name.endswith('runtime'):
        print(log, end='', flush=True)
    return child.returncode


mac = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], env=env,text=True).strip()
ios = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'], env=env,text=True).strip()
compiler = subprocess.check_output(['xcrun','swiftc','--version'],env=env,text=True).strip()
flags = ['xcrun','swiftc','-swift-version','5','-sdk',mac,
         '-module-cache-path',output / 'modules']
status = 0
for name in ['canvas-hierarchy','ipad-canvas-revisions']:
    code = run([*flags,model,root / 'Tests/checks' / name / 'main.swift','-o',output / name],name+'-compile')
    status |= code != 0
    if code == 0:
        status |= run([output / name],name+'-runtime',30) != 0

home = output / 'home'
home.mkdir(exist_ok=True)
runtime_env = dict(env, CFFIXED_USER_HOME=str(home), HOME=str(home))
plist = root / 'Tests/checks/handwriting-race/Info.plist'
code = run([*flags,'-target','arm64e-apple-macos27.0','-parse-as-library',model,store,
            here / 'main.swift','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist',
            '-Xlinker',plist,'-o',output / 'fold-check'],'fold-compile')
status |= code != 0
if code == 0:
    status |= run([output / 'fold-check'],'fold-runtime',60,runtime_env) != 0

code = run(['xcrun','swiftc','-sdk',mac,'-target','arm64e-apple-ios27.0-macabi',
            '-F',Path(mac) / 'System/iOSSupport/System/Library/Frameworks',
            '-swift-version','5','-parse-as-library','-module-cache-path',output / 'catalyst-modules',
            model,store,renderer,here / 'main.swift','-Xlinker','-sectcreate','-Xlinker','__TEXT',
            '-Xlinker','__info_plist','-Xlinker',plist,'-o',output / 'png-check'], 'png-catalyst-compile')
status |= code != 0
png_runtime = None
if code == 0:
    png_home = output / 'png-home'
    png_home.mkdir(exist_ok=True)
    png_runtime = run([output / 'png-check'],'png-runtime',60,
                      dict(env, HOME=str(png_home),CFFIXED_USER_HOME=str(png_home)))
    status |= png_runtime != 0

protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
ios_module = ['xcrun','swiftc','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5',
              '-module-cache-path',output / 'ios-modules']
code = run([*ios_module,'-emit-module','-module-name','StreamProtocol',protocol,
            '-emit-module-path',output / 'StreamProtocol.swiftmodule'],'ios-protocol')
status |= code != 0
if code == 0:
    sources = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift'))
    sources += [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift',
                root / 'iOSClient/IPadAudioSession.swift',root / 'iOSClient/IPadAudioLeaseState.swift',
                root / 'iOSClient/IPadAudioLeaseCoordinator.swift']
    status |= run([*ios_module,'-parse-as-library','-I',output,'-typecheck',*sources], 'ios-canvas-typecheck') != 0
    status |= run([*ios_module,'-parse-as-library','-typecheck',model,store,renderer,
                   here / 'main.swift'],'ios-png-tests-typecheck') != 0

after = hashes()
status |= before != after
receipt = dict(owner='01a13ace-e372-7ed1-9946-149df37ee1c3',
    base='5f6f40fa6864bd1d2ec096b94ed10318db56b4aa',worktree=str(root),
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    compiler=compiler,sourceHashes=before,sourceHashesAfter=after,sourceUnchanged=before == after,
    results=results,pngRuntimeExit=png_runtime,deviceExecuted=False,exitCode=int(bool(status)))
(output / 'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
sys.exit(int(bool(status)))

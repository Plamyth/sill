#!/usr/bin/env python3
"""Run real native file transactions and SDK checks, without installing or querying a device."""
from pathlib import Path
import os, json, subprocess, sys, hashlib
root = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('Use verified external storage')
output.mkdir(parents=True,exist_ok=True)
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
results = []
def run(name,args,runenv=env):
    result = subprocess.run(list(map(str,args)),cwd=root,env=runenv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    (output/(name+'.log')).write_text(result.stdout)
    results.append(dict(name=name,exitCode=result.returncode))
    print(name,result.returncode,flush=True)
    if result.returncode: print(result.stdout[-7000:],flush=True)
    return result.returncode
mac = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
ios = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
model = root/'iOSClient/CanvasBridge/CanvasModel.swift'
flags = ['xcrun','swiftc','-swift-version','5','-module-cache-path',output/'modules']
status = run('files-compile',flags+['-sdk',mac,'-target','arm64e-apple-macos27.0','-parse-as-library',model,root/'iOSClient/CanvasBridge/CanvasStore.swift',Path(__file__).with_name('main.swift'),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',root/'Tests/checks/handwriting-race/Info.plist','-o',output/'files-check'])
if status == 0:
    runtime_home = output/('test-home-' + __import__('uuid').uuid4().hex)
    runtime_home.mkdir(exist_ok=True)
    status |= run('files-runtime',[output/'files-check',output/('fixtures-store-' + __import__('uuid').uuid4().hex)],dict(env,HOME=str(runtime_home),CFFIXED_USER_HOME=str(runtime_home)))
code = run('png-catalyst-compile',flags+['-sdk',mac,'-target','arm64e-apple-ios27.0-macabi',
    '-F',Path(mac)/'System/iOSSupport/System/Library/Frameworks','-parse-as-library',model,
    root/'iOSClient/CanvasBridge/CanvasStore.swift',root/'iOSClient/CanvasBridge/SceneRenderer.swift',Path(__file__).with_name('main.swift'),
    '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',root/'Tests/checks/handwriting-race/Info.plist','-o',output/'png-check'])
status |= code
if code == 0:
    png_home = output/('png-home-' + __import__('uuid').uuid4().hex)
    png_home.mkdir(exist_ok=True)
    status |= run('png-catalyst-runtime',[output/'png-check',output/('png-fixtures-' + __import__('uuid').uuid4().hex)],dict(env,HOME=str(png_home),CFFIXED_USER_HOME=str(png_home)))
for name in ['canvas-hierarchy','ipad-canvas-revisions']:
    code = run(name+'-compile',flags+['-sdk',mac,model,root/'Tests/checks'/name/'main.swift','-o',output/name])
    status |= code
    if code == 0: status |= run(name+'-runtime',[output/name])
flags = ['xcrun','swiftc','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5','-module-cache-path',output/'ios-modules']
code = run('ios-protocol',flags+['-emit-module','-module-name','StreamProtocol',root/'Sources/StreamProtocol/TestDestinations.swift','-emit-module-path',output/'StreamProtocol.swiftmodule'])
status |= code
if code == 0:
    sources = sorted((root/'iOSClient/CanvasBridge').glob('*.swift'))
    sources += [root/'iOSClient'/p for p in ['TestDestinations/TestDestinationsPolicy.swift','IPadAudioSession.swift','IPadAudioLeaseState.swift','IPadAudioLeaseCoordinator.swift']]
    status |= run('ios-canvas-typecheck',flags+['-parse-as-library','-I',output,'-typecheck',*sources])
receipt = dict(base='c03d9c2de9eb39cfd50501a73a060a0a34375c8c',results=results,deviceExecuted=False,
    sourceHashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [model,root/'iOSClient/CanvasBridge/CanvasStore.swift',root/'iOSClient/CanvasBridge/CanvasWorkspace.swift']})
(output/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
sys.exit(bool(status))

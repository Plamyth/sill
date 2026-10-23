#!/usr/bin/env python3
"""Run model/Store and SDK checks; only the default mode runs WebKit and vault checks."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive',
    '--project', 'BT_CCR-ipad'], text=True))
output = Path(sys.argv[1]).resolve()
review_fix = sys.argv[2:] == ['--review-fix']
endpoints = sys.argv[2:] == ['--diagram-endpoints']
endpoint_p2 = sys.argv[2:] == ['--diagram-endpoints-p2']
if sys.argv[2:] and not (review_fix or endpoints or endpoint_p2):
    raise SystemExit('지원하지 않는 검사 옵션입니다.')
folder = 'pele-review-fix' if review_fix else 'pele-worker'
expected = Path(archive['path']) / ('diagram-endpoints-20261023/verification' if endpoints else 'pele-rea-20261021/' + folder)
if endpoint_p2:
    expected = Path(archive['path']) / 'diagram-endpoints-20261023/verification-p2'
    endpoints = True
if output != expected:
    raise SystemExit('지정된 외장 검증 경로만 사용합니다.')
output.mkdir(parents=True, exist_ok=True)
home = output / 'home'
home.mkdir(exist_ok=True)
resources = root / 'iOSClient/CanvasBridge/Pele'
relay = Path('/Users/ambrion/Documents/ChatGPT/BT_CCR-Obsidian-relay')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           PELE_OUTPUT=str(output), PELE_RESOURCES=str(resources), PELE_RELAY=str(relay),
           CFFIXED_USER_HOME=str(home))
inputs = list((root / 'iOSClient/CanvasBridge').glob('*.swift')) + list(resources.iterdir()) + list(here.iterdir())
inputs += [root / 'iOSClient/Sill.xcodeproj/project.pbxproj',relay / 'relay/obsidian-vault.js']
native = root / 'Tests/integration/ipad-runtime/CanvasBridge/CanvasModeLifetimeChecks.swift'
ui_tests = root / 'Tests/integration/ipad-runtime/CanvasBridgeUITests/CanvasBridgeUITests.swift'
ink_checks = root / 'Tests/checks/ink-undo'
if review_fix:
    inputs += [native,ui_tests,*ink_checks.glob('*.swift'),ink_checks / 'Info.plist']
if endpoints:
    inputs += [root / 'Tests/checks/canvas-hierarchy-fold/main.swift',
               root / 'Tests/checks/canvas-hierarchy/main.swift',
               root / 'Tests/checks/ipad-canvas-revisions/main.swift',
               root / 'Scripts/ipad-test-runtime/NativeSceneEncoder.swift',
               ink_checks / 'Info.plist']
inputs = [p for p in inputs if p.is_file()]
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
manifest = json.loads((resources / 'provenance.json').read_text())
for name, digest in manifest['files'].items():
    assert hashlib.sha256((resources / name).read_bytes()).hexdigest() == digest
results = []


def run(name, command, timeout=240):
    result = subprocess.run(list(map(str, command)), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    (output / (name + '.log')).write_text(result.stdout)
    print(name, result.returncode, flush=True)
    if result.stdout:
        print(result.stdout[-9000:], end='', flush=True)
    results.append(dict(name=name, command=list(map(str, command)), exitCode=result.returncode))
    if result.returncode:
        raise RuntimeError(name)


status = 0
try:
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    iphone = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    base = ['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5',
            '-module-cache-path',output / 'mac-modules']
    model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
    store = root / 'iOSClient/CanvasBridge/CanvasStore.swift'
    suites = [] if endpoint_p2 else [here / 'main.swift', root / 'Tests/checks/ipad-canvas-revisions/main.swift',
                                    root / 'Tests/checks/canvas-hierarchy/main.swift']
    for suite in suites:
        name = suite.parent.name
        binary = output / name
        run(name + '-compile',base + [model,suite,'-o',binary])
        run(name + '-run',[binary],30)
    plist = root / 'Tests/checks/ink-undo/Info.plist'
    run('store-compile',base + ['-parse-as-library',model,store,here / 'StoreChecks.swift',
        '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',plist,
        '-o',output / 'store-check'])
    run('store-run',[output / 'store-check'],30)
    if endpoints:
        checks = [('endpoints', here / 'EndpointChecks.swift')]
        if not endpoint_p2:
            checks.append(('fold', root / 'Tests/checks/canvas-hierarchy-fold/main.swift'))
        for name, checks in checks:
            run(name + '-compile',base + ['-parse-as-library',model,store,checks,
                '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',plist,
                '-o',output / (name + '-check')])
            run(name + '-run',[output / (name + '-check')],60)
        run('native-scene-encoder-compile',base + ['-parse-as-library',model,
            root / 'Scripts/ipad-test-runtime/NativeSceneEncoder.swift','-o',output / 'native-scene-encoder'])
        original = (output / 'endpoint-scene.json').read_bytes()
        typed = subprocess.run([str(output / 'native-scene-encoder')],input=original,env=env,
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
        (output / 'native-scene-encoder.log').write_bytes(typed.stderr)
        (output / 'native-scene-readback.json').write_bytes(typed.stdout)
        equivalent = typed.returncode == 0 and json.loads(original) == json.loads(typed.stdout)
        results.append(dict(name='native-scene-roundtrip',exitCode=0 if equivalent else 1,
                            processExitCode=typed.returncode,equivalent=equivalent))
        if not equivalent:
            raise RuntimeError('native scene encoder lost data')
        print('native-scene-roundtrip 0',flush=True)
    elif review_fix:
        run('ink-history-compile',base + ['-parse-as-library',model,store,
            ink_checks / 'InkUndoChecks.swift',ink_checks / 'main.swift',
            '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',plist,
            '-o',output / 'ink-history-check'])
        run('ink-history-run',[output / 'ink-history-check'],30)
    else:
        run('webkit-compile',base + ['-parse-as-library',here / 'WebKitChecks.swift','-o',output / 'webkit-check'])
        run('webkit-run',[output / 'webkit-check'],60)
        run('vault-run',['node',here / 'vault-check.cjs'],30)
    ios = output / 'ios'
    ios.mkdir(exist_ok=True)
    iosbase = ['xcrun','swiftc','-sdk',iphone,'-target','arm64-apple-ios27.0','-swift-version','5',
               '-module-cache-path',output / 'ios-modules']
    run('ios-module',iosbase + ['-emit-module','-module-name','StreamProtocol',
        root / 'Sources/StreamProtocol/TestDestinations.swift','-emit-module-path',ios / 'StreamProtocol.swiftmodule'])
    sources = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift'))
    sources += [root / ('iOSClient/' + name + '.swift') for name in
                ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']]
    sources += [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
    run('ios-typecheck',iosbase + ['-parse-as-library','-I',ios,'-typecheck',*sources])
    if review_fix:
        run('native-mode-typecheck',iosbase + ['-D','DEBUG','-D','CANVAS_MODE_LIFETIME_CHECK','-parse-as-library','-I',ios,
            '-typecheck',*sources,native])
        frameworks = Path(env['DEVELOPER_DIR']) / 'Platforms/iPhoneOS.platform/Developer/Library/Frameworks'
        swift_tests = frameworks.parent.parent / 'usr/lib'
        run('ui-tests-typecheck',iosbase + ['-parse-as-library','-F',frameworks,'-I',swift_tests,
            '-typecheck',ui_tests])
    if not endpoint_p2:
        run('project-format',['plutil','-lint',root / 'iOSClient/Sill.xcodeproj/project.pbxproj',
            root / 'Tests/integration/ipad-runtime/CanvasBridge.xcodeproj/project.pbxproj'])
except Exception as error:
    print(str(error),flush=True)
    status = 1
after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
if hashes != after:
    status = 1
(output / 'result.json').write_text(json.dumps(dict(results=results,inputHashes=hashes,
    inputsUnchanged=hashes == after,head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    realVaultTouched=False,deviceExecuted=False,nativeModeExecuted=False,sharedHostChanged=False,
    reviewFix=review_fix,diagramEndpoints=endpoints,endpointP2=endpoint_p2,exitCode=status),indent=2) + '\n')
sys.exit(status)

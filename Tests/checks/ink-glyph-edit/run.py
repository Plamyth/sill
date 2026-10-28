#!/usr/bin/env python3
"""실제 PencilKit 실행, 접합 Store 파일 왕복, iOS SDK 검사. 기기·앱·Host를 열지 않는다."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--actual-product', action='store_true')
parser.add_argument('--policy-only', action='store_true')
args = parser.parse_args()
assert any(parent.exists() and os.path.samefile(parent, route['path']) for parent in [args.output, *args.output.parents]), 'output must use verified storage-route archive'
args.output.mkdir(parents=True, exist_ok=True)
args.output = Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())
output = args.output / ('policy-' + str(uuid.uuid4()))
output.mkdir(parents=True)
home = output / 'home'
home.mkdir()
tmp = output / 'tmp'
tmp.mkdir()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(tmp) + '/', INK_GLYPH_OUTPUT=str(output))
mac_sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
ios_sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
product = root / 'iOSClient/CanvasBridge/CanvasInkTextEditing.swift'
model = root / 'iOSClient/CanvasBridge/CanvasModel.swift'
original_store = root / 'iOSClient/CanvasBridge/CanvasStore.swift'
workspace = root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift'
actual = args.actual_product
if actual:
    patched_store, patched_workspace = original_store, workspace
else:
    for source in [original_store, workspace]:
        dest = output / source.relative_to(root)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(source.read_bytes())
    subprocess.run(['git', 'apply', '--check', str(here / 'integration.patch')], cwd=root, check=True)
    subprocess.run(['/usr/bin/patch', '--batch', '-p1', '-i', str(here / 'integration.patch')], cwd=output, check=True, capture_output=True)
    patched_store = output / original_store.relative_to(root)
    patched_workspace = output / workspace.relative_to(root)
all_canvas = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift'))
extras = [root / ('iOSClient/' + name + '.swift') for name in ['IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator']]
extras += [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
module = root / 'Sources/StreamProtocol/TestDestinations.swift'
inputs = list(dict.fromkeys(all_canvas + extras + [module, here / 'main.swift', here / 'Info.plist', here / 'integration.patch', Path(__file__).resolve()]))
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
results = []

def run(name, command, timeout=300):
    try:
        result = subprocess.run(list(map(str, command)), cwd=root, env=env, capture_output=True, text=True, timeout=timeout)
        log = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        log = '명시된 검사 시간 예산 소진\n' + str(error)
        code = 124
    (output / (name + '.log')).write_text(log)
    record = dict(name=name, exitCode=code, command=list(map(str, command)))
    print(name, code, log[-9000:] if code else log[-2500:], flush=True)
    return record

mac = ['xcrun', 'swiftc', '-sdk', mac_sdk, '-target', 'arm64e-apple-macos27.0', '-swift-version', '5',
       '-parse-as-library', '-module-cache-path', str(output / 'mac-modules')]
link = ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(here / 'Info.plist')]
shape = root / 'iOSClient/CanvasBridge/CanvasInkShapeProposal.swift'
math = root / 'iOSClient/CanvasBridge/CanvasInkMathProposal.swift'
compile_command = mac + ['-D', 'INK_GLYPH_INTEGRATION', model, patched_store, product] + ([shape] if shape.exists() else []) + ([math] if math.exists() else []) + [here / 'main.swift'] + link + ['-o', output / 'check']

def sdk():
    base = ['xcrun', 'swiftc', '-sdk', ios_sdk, '-target', 'arm64-apple-ios27.0', '-swift-version', '5',
            '-module-cache-path', str(output / 'ios-modules')]
    mod = run('ios-module', base + ['-emit-module', '-module-name', 'StreamProtocol', module,
        '-emit-module-path', output / 'StreamProtocol.swiftmodule'])
    result = [mod]
    if mod['exitCode'] == 0:
        sources = [patched_store if p == original_store else patched_workspace if p == workspace else p for p in all_canvas]
        result.append(run('ios-product-and-junction', base + ['-parse-as-library', '-I', output, '-typecheck'] + sources + extras))
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    future = pool.submit(sdk)
    compiled = run('mac-native-compile', compile_command)
    results.append(compiled)
    if compiled['exitCode'] == 0:
        fixtures = []
        if not args.policy_only:
            fixtures = sorted((Path(route['path']) / 'rea-margin-native-backup-20261023/native-archives').glob('*.pkdrawing'))
            assert len(fixtures) == 3
        results.append(run('native-and-store', [output / 'check'] + fixtures, timeout=240))
    results += future.result()
unchanged = before == hashes()
record = dict(schema='ccr.ink-glyph-verification/v1', baseCommit='68a1b4aaad6faba5a5449d82b81e147479b81930' if actual else 'c03d9c2de9eb39cfd50501a73a060a0a34375c8c',
    sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(), sourceTree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(), sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(), sourceHashes=before, sourceHashesAfter=hashes(), sourceUnchanged=unchanged,
    output=str(output), results=results, passed=unchanged and all(x['exitCode'] == 0 for x in results),
    actualRecognizer='미실행; 보존된 무주입 baseline을 참조' if args.policy_only else '실제 native API, 증거 주입 없음',
    mappingAndStorePolicy='증거 주입. native 인식 정확도 수용이 아님.',
    productOriginalStoreAndWorkspaceUnchanged=not actual, actualProductSources=actual, deviceHostEffects=0,
    nativeRecognizerExecuted=not args.policy_only,
    executionHostReason='Mini는macOS26.6.2/SDK26.5이며PKStrokeRecognizer27이없음. 실제27PencilKit/SDK검사만맥북에서실행.')
for name in ['summary.json', 'native-recognizer.json']:
    p = output / name
    if p.exists():
        record[name] = json.loads(p.read_text())
(output / 'verification.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print('OUTPUT', output, 'PASSED', record['passed'])
sys.exit(0 if record['passed'] else 1)

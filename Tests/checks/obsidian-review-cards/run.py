#!/usr/bin/env python3
"""Compile the real model/store on Mini using a bounded ephemeral source input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--worker', action='store_true')
parser.add_argument('--native-worker', action='store_true')
parser.add_argument('--markdown-context', action='store_true')
parser.add_argument('--token-boundary', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
if args.markdown_context or args.token_boundary:
    route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
    output = args.output.resolve()
    assert output.is_relative_to(Path(route['path']).resolve())
    output.mkdir(parents=True,exist_ok=True)
    for name in ['modules','home','tmp']: (output/name).mkdir(exist_ok=True)
    selected = [root/'iOSClient/CanvasBridge/CanvasModel.swift',Path(__file__).with_name('ClozeTokenBoundaryChecks.swift' if args.token_boundary else 'ClozeMarkdownContextChecks.swift')]
    before = {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in selected+[Path(__file__)]}
    env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(output/'home'),TMPDIR=str(output/'tmp')+'/')
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    command = ['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',str(output/'modules'),*map(str,selected),'-o',str(output/'check')]
    results=[]
    for name,cmd in [('compile',command),('native',[str(output/'check'),str(output)])]:
        r=subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,timeout=120)
        (output/(name+'.log')).write_text(r.stdout+r.stderr);results.append(dict(name=name,exitCode=r.returncode,command=cmd));print(name,r.returncode,(r.stdout+r.stderr)[-1500:],flush=True)
        if r.returncode: break
    after={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in before}
    passed=len(results)==2 and all(r['exitCode']==0 for r in results) and before==after and not (output/'home/Library/Application Support').exists()
    (output/'result.json').write_text(json.dumps(dict(inputs=before,after=after,sourceUnchanged=before==after,results=results,passed=passed,ModelOnly=True,StoreExecuted=False,whole95Repeated=False,wholeSDKRepeated=False,GUI=False,HTTP=False),indent=2)+'\n')
    sys.exit(0 if passed else 1)
inputs = ['iOSClient/CanvasBridge/CanvasModel.swift', 'iOSClient/CanvasBridge/CanvasStore.swift',
          'iOSClient/CanvasBridge/CanvasWorkspace.swift',
          'Tests/checks/obsidian-review-cards/main.swift', 'Tests/checks/obsidian-review-cards/run.py']


def hashes(names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


if args.worker or args.native_worker:
    if args.worker and not str(root).startswith('/Users/sin-wonho/.local/share/mini-ephemeral-source/runs/'):
        raise SystemExit('Worker requires the approved task-scoped Mini input')
    output = args.output.resolve()
    if args.worker and not output.is_relative_to(root):
        raise SystemExit('Worker output must remain inside its ephemeral input')
    if args.native_worker:
        route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
            'development-archive', '--project', 'BT_CCR-ipad'], text=True))
        if not output.is_relative_to(Path(route['path']).resolve()):
            raise SystemExit('Native output must use the verified storage-route archive')
        os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    output.mkdir(parents=True, exist_ok=True)
    before = hashes(inputs)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip()
    info = output / 'Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.ambrion.CCRReviewChecks',
                                     'CFBundleName': 'CCRReviewChecks'}))
    selected = [inputs[0], inputs[-2]] if args.worker else [inputs[0], inputs[1], inputs[-2]]
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
               '-module-cache-path', str(output / 'modules'),
               *(['-DREVIEW_MODEL_ONLY'] if args.worker else ['-target', 'arm64e-apple-macos27.0']),
               *[str(root / name) for name in selected],
               '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
               '-Xlinker', str(info), '-o', str(output / 'checks')]
    syntax = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', str(root / inputs[2])],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    print(syntax.stdout, end='', flush=True)
    compiled = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
    print(compiled.stdout, end='', flush=True)
    code = compiled.returncode or syntax.returncode
    if code == 0:
        home = output / 'home'
        home.mkdir(exist_ok=True)
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), CCR_REVIEW_ROOT=str(home))
        ran = subprocess.run([str(output / 'checks')], env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        print(ran.stdout, end='', flush=True)
        code = ran.returncode
    after = hashes(inputs)
    code = code or int(before != after)
    print('REVIEW_RECEIPT ' + json.dumps({'inputHashes': before, 'afterHashes': after,
        'inputsUnchanged': before == after, 'sdk': sdk, 'compiler': compiler,
        'command': command, 'mode': 'Mini pure model' if args.worker else 'MacBook narrow native Store SDK',
        'workspaceSyntaxExitCode': syntax.returncode, 'exitCode': code, 'deviceExecuted': False,
        'uiExecuted': False,
        'installedOrLiveVaultTouched': False,
        'defaults': 'absolute preferences path beneath isolated root; physical plist and separate-process restore; added scope key removed using official API'}), flush=True)
    sys.exit(0 if code == 0 else 1)

route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'BT_CCR-ipad'], text=True))
output = args.output.resolve()
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('Output must use the verified storage-route archive')
output.mkdir(parents=True, exist_ok=True)
all_inputs = inputs
before = hashes(all_inputs)
staged = output / 'input'
for name in inputs:
    destination = staged / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / name, destination)
if 'defaults:defaults' not in (root / inputs[-2]).read_text():
    raise SystemExit('Every native Store fixture must inject the absolute isolated defaults suite')
command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(staged),
    '--owner', os.environ.get('CODEX_THREAD_ID', 'ipad-review-cards-integration-20261026'), '--job', 'ipad-review-card-editing',
    '--', 'python3', '-B', 'Tests/checks/obsidian-review-cards/run.py', 'output', '--worker']
result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=420)
(output / 'mini.log').write_text(result.stdout)
print(result.stdout, end='')
after = hashes(all_inputs)
receipts = [json.loads(line[len('REVIEW_RECEIPT '):]) for line in result.stdout.splitlines()
            if line.startswith('REVIEW_RECEIPT ')]
cleanup = [json.loads(line) for line in result.stdout.splitlines()
           if line.startswith('{"receipt":')]
remote = receipts[-1] if receipts else None
native_command = [sys.executable, '-B', str(Path(__file__).resolve()), str(output / 'native'), '--native-worker']
native = subprocess.run(native_command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=360)
(output / 'native.log').write_text(native.stdout)
print(native.stdout, end='')
native_receipts = [json.loads(line[len('REVIEW_RECEIPT '):]) for line in native.stdout.splitlines()
                   if line.startswith('REVIEW_RECEIPT ')]
native_receipt = native_receipts[-1] if native_receipts else None
after = hashes(all_inputs)
accepted = (result.returncode == 0 and before == after and remote is not None and remote['exitCode'] == 0
            and remote['inputHashes'] == {name: before[name] for name in inputs}
            and cleanup and cleanup[-1]['cleanup_verified'] and native.returncode == 0
            and native_receipt and native_receipt['inputHashes'] == before and native_receipt['exitCode'] == 0)
staged_matches = all(hashlib.sha256((staged / name).read_bytes()).hexdigest() == before[name] for name in inputs)
if staged_matches:
    shutil.rmtree(staged)
local_cleanup = staged_matches and not staged.exists()
(output / 'result.json').write_text(json.dumps({'inputHashes': before, 'afterHashes': after,
    'sourceUnchanged': before == after, 'mini': remote, 'native': native_receipt,
    'cleanup': cleanup, 'localStagedInputCleanupVerified': local_cleanup, 'accepted': bool(accepted and local_cleanup),
    'independentReview': 'parent-owned pending', 'iOSSDKAndUI': 'parent-owned pending'}, indent=2) + '\n')
sys.exit(0 if accepted and local_cleanup else 1)

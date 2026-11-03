#!/usr/bin/env python3
"""실제 Store snapshot과 제품 PDF helper를 격리 native 프로세스로 검사한다."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
archive = Path(json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'
], text=True))['path']).resolve()
out = args.output.resolve()
assert out.is_relative_to(archive / 'rea-followup-20261103')
out.mkdir(parents=True, exist_ok=False)
for name in ['home', 'tmp', 'modules']:
    (out / name).mkdir()
canvas = root / 'iOSClient/CanvasBridge'
names = ['CanvasModel', 'CanvasDocument', 'CanvasDocumentFiles', 'CanvasDocumentRelay', 'VaultPDFExcerpt',
         'VaultPDFViewState', 'CanvasCardTags', 'CanvasStore', 'CanvasInkTextEditing', 'CanvasInkShapeProposal',
         'CanvasInkMathProposal', 'CanvasInkSpacingProposal', 'CanvasCardMerge', 'CanvasRelay',
         'ControlRoomProjection', 'VaultEPUB', 'VaultEPUBExcerpt', 'VaultEPUBReader', 'SceneFile']
sources = [canvas / (name + '.swift') for name in names] + [
    root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift', Path(__file__).with_name('main.swift')]
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
reader = out / 'PDFNativeReader.swift'
reader.write_text((canvas / 'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
inputs = sources + [protocol, canvas / 'VaultPDFReader.swift', canvas / 'CanvasWorkspace.swift', Path(__file__)]
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
before = {str(path.relative_to(root)): sha(path) for path in inputs}
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip()
info = plistlib.loads((root / 'Tests/checks/ink-glyph-edit/Info.plist').read_bytes())
info.update(CCRSourceCommit=commit, CCRSourceTree=tree)
(out / 'Info.plist').write_bytes(plistlib.dumps(info))
identity = 'f402ef41-c849-4bc3-8acc-166200161103'
support = out / 'home/Library/Application Support'
state = support / 'CCRIntegrationTests' / identity / 'state'
state.mkdir(parents=True)
(state.parent / 'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1', id=identity,
    commit=commit, tree=tree, relayAddress='http://192.168.88.88:4242', token='own-outline-export-fixture-01234567890123456789')))
protected = {}
for name in ['CanvasScene.json', 'CanvasDocumentSource.json', 'CanvasPreferences.json', 'CanvasWorkspace/bookmark.json']:
    path = support / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('normal sentinel ' + name)
    protected[str(path)] = sha(path)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp') + '/')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
base = ['xcrun', 'swiftc', '-D', 'DEBUG', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0', '-swift-version', '5',
        '-parse-as-library', '-whole-module-optimization', '-module-cache-path', out / 'modules']
commands = [
    ('protocol', base + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol', protocol,
        '-emit-module-path', out / 'StreamProtocol.swiftmodule', '-o', out / 'StreamProtocol.o']),
    ('compile', base + ['-I', out, *sources, reader, out / 'StreamProtocol.o', '-Xlinker', '-sectcreate',
        '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', out / 'Info.plist', '-o', out / 'check']),
    ('native', [out / 'check', out, '--ccr-test-runtime', identity])]
results = []
for label, command in commands:
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = subprocess.run(list(map(str, command)), cwd=root, env=env, capture_output=True, text=True, timeout=240)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    print(label, result.returncode, (result.stdout + result.stderr)[-7000:], flush=True)
    results.append(dict(stage=label, command=list(map(str, command)), timeUTC=started, exitCode=result.returncode))
    if result.returncode:
        break
after = {str(path.relative_to(root)): sha(path) for path in inputs}
normal_unchanged = all(sha(Path(path)) == value for path, value in protected.items())
passed = len(results) == len(commands) and all(item['exitCode'] == 0 for item in results) and before == after and normal_unchanged
artifacts = {path.name: sha(path) for path in out.glob('*.pdf')}
(out / 'result.json').write_text(json.dumps(dict(passed=passed, commit=commit, tree=tree,
    sourceBefore=before, sourceAfter=after, sourceUnchanged=before == after, normalUnchanged=normal_unchanged,
    commands=results, artifacts=artifacts, actualStore=True, actualProductPDFHelper=True,
    host='MacBook; SDK CoreText/PDFKit/PencilKit required; no portable CPU-only substitute',
    UI=False, device=False, installation=False, Pencil=False, originalAppParity=False,
    independentReview='parent-owned pending'), ensure_ascii=False, indent=2) + '\n')
raise SystemExit(0 if passed else 1)

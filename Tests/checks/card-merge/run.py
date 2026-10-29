#!/usr/bin/env python3
"""Actual Model/Store/PKDrawing/file checks. No device, UI, service, or live vault."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import uuid

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--sdk-check', action='store_true')
parser.add_argument('--group-submap', action='store_true')
args = parser.parse_args()
archive = Path(json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'
], text=True))['path']).resolve()
assert args.output.resolve().is_relative_to(archive)
args.output.mkdir(parents=True, exist_ok=True)
out = args.output.resolve() / ('run-' + str(uuid.uuid4()))
out.mkdir()
for name in ['home', 'tmp']:
    (out / name).mkdir()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp') + '/')
canvas = root / 'iOSClient/CanvasBridge'
sources = [canvas / (name + '.swift') for name in [
    'CanvasModel', 'CanvasDocument', 'CanvasDocumentFiles', 'CanvasDocumentRelay', 'VaultPDFExcerpt', 'VaultPDFViewState', 'CanvasCardTags', 'CanvasStore', 'CanvasInkTextEditing', 'CanvasInkShapeProposal',
    'CanvasInkMathProposal', 'CanvasInkSpacingProposal', 'CanvasCardMerge', 'CanvasRelay', 'ControlRoomProjection', 'VaultEPUB', 'VaultEPUBExcerpt', 'VaultEPUBReader'
]] + [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift', here / 'main.swift', here / 'GroupChecks.swift']
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
native_reader = out / 'PDFNativeReader.swift'
native_reader.write_text((canvas / 'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
sources.append(native_reader)
ios_sources = sorted(canvas.glob('*.swift')) + [root / 'iOSClient' / (n + '.swift') for n in [
    'IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator'
]] + [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
project = root / 'iOSClient/Sill.xcodeproj/project.pbxproj'
inputs = list(dict.fromkeys([p for p in sources if p != native_reader] + [canvas / 'VaultPDFReader.swift', protocol, project, canvas / 'CanvasWorkspace.swift', Path(__file__)] +
                           (ios_sources if args.sdk_check else [])))
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip()
info = plistlib.loads((root / 'Tests/checks/ink-glyph-edit/Info.plist').read_bytes())
info.update(CCRSourceCommit=commit, CCRSourceTree=tree)
(out / 'Info.plist').write_bytes(plistlib.dumps(info))
identity = str(uuid.uuid4())
support = out / 'home/Library/Application Support'
state = support / 'CCRIntegrationTests' / identity / 'state'
state.mkdir(parents=True)
(state.parent / 'context.json').write_text(json.dumps(dict(
    schema='ccr.ipad-test-context/v1', id=identity, commit=commit, tree=tree,
    relayAddress='http://192.168.88.88:4242', token='own-card-fixture-01234567890123456789')))
protected = {}
for name in ['CanvasScene.json', 'CanvasWorkspace/bookmark.json', 'CanvasPreferences.json',
             'CanvasConflictRecovery/CanvasConflictChoice.json', 'CanvasNoteEdit/recovery.json']:
    p = support / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(('normal sentinel ' + name).encode())
    protected[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
base = ['xcrun', 'swiftc', '-D', 'DEBUG', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
        '-swift-version', '5', '-parse-as-library', '-module-cache-path', out / 'modules']
commands = [
    ('protocol', base + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol', protocol,
                        '-emit-module-path', out / 'StreamProtocol.swiftmodule', '-o', out / 'StreamProtocol.o']),
    ('compile', base + ['-I', out, *sources, out / 'StreamProtocol.o', '-Xlinker', '-sectcreate', '-Xlinker',
                       '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', out / 'Info.plist', '-o', out / 'check']),
    ('product-runtime', [out / 'check', out, *(['--group-submap'] if args.group_submap else []), '--ccr-test-runtime', identity]),
    ('project-plist', ['plutil', '-lint', project]),
]
if args.group_submap:
    commands += [('group-fresh-reopen', [out / 'check', out, '--group-submap-reopen', '--ccr-test-runtime', identity]),
                 ('group-document', [out / 'check', out, '--group-submap-document', '--ccr-test-runtime', identity])]
if args.sdk_check:
    sdk_ios = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
    (out / 'ios').mkdir()
    ios = ['xcrun', 'swiftc', '-D', 'DEBUG', '-sdk', sdk_ios, '-target', 'arm64-apple-ios27.0',
           '-swift-version', '5', '-module-cache-path', out / 'ios-modules']
    commands += [
        ('ios-protocol', ios + ['-emit-module', '-module-name', 'StreamProtocol', protocol,
                               '-emit-module-path', out / 'ios/StreamProtocol.swiftmodule']),
        ('ios-product-typecheck', ios + ['-parse-as-library', '-I', out / 'ios', '-typecheck', *ios_sources]),
    ]
results = []
for name, command in commands:
    result = subprocess.run(list(map(str, command)), env=env, cwd=root, capture_output=True, text=True, timeout=240)
    log = result.stdout + result.stderr
    (out / (name + '.log')).write_text(log)
    print(name, result.returncode, log[-6500:], flush=True)
    results.append(dict(name=name, exitCode=result.returncode, command=list(map(str, command))))
    if result.returncode:
        break
unchanged = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in protected.items())
record = dict(commit=commit, tree=tree, sourceHashes=before, sourceHashesAfter=hashes(),
              sourceUnchanged=before == hashes(), output=str(out), results=results,
              passed=len(results) == len(commands) and all(r['exitCode'] == 0 for r in results) and
              unchanged and before == hashes(), normalFixtureHashes=protected, normalFixturesUnchanged=unchanged,
              testRuntimeIsolated=True, actualProductSources=True, previewFixture=True,
              device=False, GUI=False, HTTP=False, service=False, liveVault=False,
              sourceFeatureAccepted=False, independentReview='pending')
(out / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print('CARD_MERGE_OUTPUT', out, flush=True)
raise SystemExit(0 if record['passed'] else 1)

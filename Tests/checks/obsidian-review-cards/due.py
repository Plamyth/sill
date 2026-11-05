#!/usr/bin/env python3
"""기존 복습 원문의 기한 필터와 실제 격리 Obsidian 파일 왕복을 검사한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--mini-worker', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
out = args.output.resolve()
canvas = root / 'iOSClient/CanvasBridge'
checks = Path(__file__).parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if args.mini_worker:
    assert str(root).startswith('/Users/sin-wonho/.local/share/mini-ephemeral-source/runs/')
    assert out.is_relative_to(root)
else:
    route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
        'development-archive', '--project', 'BT_CCR-ipad'], text=True))
    assert out.is_relative_to(Path(route['path']).resolve())
out.mkdir(parents=True, exist_ok=False)

def run(name, command, env=None):
    result = subprocess.run(list(map(str, command)), cwd=root, env=env, text=True,
        capture_output=True, timeout=300)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    print(name, result.returncode, (result.stdout + result.stderr)[-3000:], flush=True)
    return dict(name=name, command=list(map(str, command)), exitCode=result.returncode)

model_inputs = [canvas / 'CanvasModel.swift', checks / 'DueChecks.swift', Path(__file__)]
if args.mini_worker:
    before = {str(p.relative_to(root)): digest(p) for p in model_inputs}
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    commands = [run('compile-model', ['xcrun', 'swiftc', '-DREVIEW_MODEL_ONLY', '-sdk', sdk,
        '-swift-version', '5', '-parse-as-library', '-module-cache-path', out / 'modules',
        *model_inputs[:2], '-o', out / 'check'])]
    if commands[-1]['exitCode'] == 0:
        commands.append(run('model', [out / 'check']))
    after = {str(p.relative_to(root)): digest(p) for p in model_inputs}
    passed = len(commands) == 2 and all(c['exitCode'] == 0 for c in commands) and before == after
    print('DUE_MODEL_RECEIPT ' + json.dumps(dict(inputs=before, after=after, passed=passed)))
    raise SystemExit(0 if passed else 1)

names = ['CanvasModel', 'CanvasDocument', 'CanvasDocumentFiles', 'CanvasStore', 'VaultPDFExcerpt',
    'VaultPDFViewState', 'CanvasCardMerge', 'CanvasCardTags', 'CanvasInkTextEditing',
    'CanvasInkShapeProposal', 'CanvasInkMathProposal', 'CanvasInkSpacingProposal', 'CanvasRelay',
    'CanvasDocumentRelay', 'ControlRoomProjection', 'VaultEPUB', 'VaultEPUBExcerpt', 'VaultEPUBReader']
sources = [canvas / (name + '.swift') for name in names]
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
policy = root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift'
ios_sources = sorted(canvas.glob('*.swift')) + [policy] + [root / ('iOSClient/' + name + '.swift')
    for name in ['IPadAudioSession', 'IPadAudioLeaseState', 'IPadAudioLeaseCoordinator']]
backend = root / 'Tests/checks/epub-product/vault.cjs'
relay_sources = sorted((root / 'CanvasRelay/relay').glob('*.js')) + sorted((root / 'CanvasRelay/relay').glob('*.py')) + [root / 'CanvasRelay/test-guard.cjs', backend]
inputs = list(dict.fromkeys(model_inputs + sources + ios_sources + [protocol, backend] + relay_sources))
before = {str(p.relative_to(root)): digest(p) for p in inputs}
staged = out / 'mini-input'
for path in model_inputs:
    destination = staged / path.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, destination)
mini = run('mini', ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', staged,
    '--owner', os.environ['CODEX_THREAD_ID'], '--job', 'ipad-review-due-20261105', '--',
    'python3', '-B', 'Tests/checks/obsidian-review-cards/due.py', '--output', 'output', '--mini-worker'])
mini_log = (out / 'mini.log').read_text()
cleanup = [json.loads(line) for line in mini_log.splitlines() if line.startswith('{"receipt":')]
model = [json.loads(line[len('DUE_MODEL_RECEIPT '):]) for line in mini_log.splitlines()
    if line.startswith('DUE_MODEL_RECEIPT ')]
staged_matches = all(digest(staged / p.relative_to(root)) == before[str(p.relative_to(root))] for p in model_inputs)
if staged_matches:
    shutil.rmtree(staged)
commands = [mini]
if mini['exitCode'] == 0 and cleanup and cleanup[-1]['cleanup_verified']:
    for name in ['home', 'tmp', 'modules', 'vault/Notes', 'ios']:
        (out / name).mkdir(parents=True)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip()
    identity = str(uuid.uuid4())
    support = out / 'home/Library/Application Support'
    state = support / 'CCRIntegrationTests' / identity / 'state'
    state.mkdir(parents=True)
    (state.parent / 'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',
        id=identity, commit=commit, tree=tree, relayAddress='http://192.168.88.88:4242',
        token='own-review-due-fixture-01234567890123456789')))
    info = out / 'Info.plist'
    info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='dev.ambrion.CCRReviewDueChecks',
        CCRSourceCommit=commit, CCRSourceTree=tree)))
    protected = {}
    for name in ['CanvasScene.json', 'CanvasDocumentSource.json', 'CanvasConflictRecovery/NoteConflictChoice.json']:
        file = support / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text('normal sentinel ' + name)
        protected[str(file)] = digest(file)
    reader = out / 'PDFNativeReader.swift'
    reader.write_text((canvas / 'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
        CFFIXED_USER_HOME=str(out / 'home'), TMPDIR=str(out / 'tmp') + '/',
        EPUB_PRODUCT_NODE=shutil.which('node'), EPUB_PRODUCT_BACKEND=str(backend), EPUB_PRODUCT_VAULT=str(out / 'vault'))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    base = ['xcrun', 'swiftc', '-D', 'DEBUG', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
        '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-module-cache-path', out / 'modules']
    steps = [('protocol', base + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol', protocol,
        '-emit-module-path', out / 'StreamProtocol.swiftmodule', '-o', out / 'StreamProtocol.o']),
        ('compile-store', base + ['-I', out, *sources, policy, checks / 'DueChecks.swift', reader,
        out / 'StreamProtocol.o', '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
        '-Xlinker', info, '-o', out / 'check']),
        ('store-obsidian', [out / 'check', out, '--ccr-test-runtime', identity])]
    for name, command in steps:
        commands.append(run(name, command, env))
        if commands[-1]['exitCode']:
            break
    if commands[-1]['exitCode'] == 0:
        for failure in ['409', 'lost-response', 'lost-readback', 'cleanup']:
            case_id = str(uuid.uuid4())
            case_root = support / 'CCRIntegrationTests' / case_id
            (case_root / 'state').mkdir(parents=True)
            case_context = json.loads((state.parent / 'context.json').read_text())
            case_context['id'] = case_id
            (case_root / 'context.json').write_text(json.dumps(case_context))
            commands.append(run('store-' + failure, [out / 'check', out, '--failure=' + failure,
                '--ccr-test-runtime', case_id], env))
            if commands[-1]['exitCode']:
                break
    if commands[-1]['exitCode'] == 0:
        iphone = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=env, text=True).strip()
        ios_base = ['xcrun', 'swiftc', '-sdk', iphone, '-target', 'arm64-apple-ios27.0',
            '-swift-version', '5', '-module-cache-path', out / 'ios-modules']
        commands.append(run('ios-protocol', ios_base + ['-emit-module', '-module-name', 'StreamProtocol',
            protocol, '-emit-module-path', out / 'ios/StreamProtocol.swiftmodule'], env))
        if commands[-1]['exitCode'] == 0:
            commands.append(run('ios-typecheck', ios_base + ['-I', out / 'ios', '-parse-as-library',
                '-typecheck', *ios_sources], env))
    normal_unchanged = all(digest(Path(p)) == sha for p, sha in protected.items())
else:
    normal_unchanged = None
children = [json.loads(line) for line in (out / 'tmp/children.jsonl').read_text().splitlines()] if (out / 'tmp/children.jsonl').exists() else []
after = {str(p.relative_to(root)): digest(p) for p in inputs}
passed = (len(commands) == 10 and all(c['exitCode'] == 0 for c in commands) and before == after
    and cleanup and cleanup[-1]['cleanup_verified'] and model and model[-1]['passed']
    and not staged.exists() and normal_unchanged and children and all(c['pidGone'] and c['exitCode'] == 0 for c in children))
receipt = dict(inputs=before, after=after, sourceUnchanged=before == after, commands=commands,
    miniCleanup=cleanup, model=model, normalUnchanged=normal_unchanged, helperChildren=children,
    localStagedInputCleanupVerified=not staged.exists(), passed=bool(passed),
    localNativeReason='PencilKit 616 and iOS 27 SDK exist on MacBook; Mini SDK 26.5 executes the pure model',
    actualStore=True, actualObsidianFiles=True, HTTP=False, UI=False, device=False, installed=False,
    independentReview='parent-owned pending', sourceGuardTransferAccepted=False)
(out / 'result.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
raise SystemExit(0 if passed else 1)

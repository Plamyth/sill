#!/usr/bin/env python3
import hashlib
import json
import plistlib
import re
import os
import signal
import shutil
import uuid
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
if not any(parent.exists() and parent.samefile(archive['path']) for parent in [output, *output.parents]):
    raise SystemExit('Output must use the verified storage-route development archive')
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'iOSClient/CanvasBridge/CanvasModel.swift',
           root / 'iOSClient/CanvasBridge/VaultPDFExcerpt.swift',
           root / 'iOSClient/CanvasBridge/CanvasStore.swift',
           root / 'iOSClient/CanvasBridge/PencilTextCorrection.swift',
           root / 'iOSClient/CanvasBridge/CanvasInkTextEditing.swift',
           root / 'iOSClient/CanvasBridge/CanvasInkShapeProposal.swift',
           root / 'iOSClient/CanvasBridge/CanvasInkMathProposal.swift',
           root / 'iOSClient/CanvasBridge/CanvasRelay.swift',
           root / 'iOSClient/CanvasBridge/ControlRoomProjection.swift',
           root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift',
           Path(__file__).with_name('BlockExcerptChecks.swift'),
           Path(__file__).with_name('SelectedInkChecks.swift'),
           Path(__file__).with_name('HandwritingSearchChecks.swift'),
           Path(__file__).with_name('WholeNoteRecoveryChecks.swift'),
           Path(__file__).with_name('PencilVaultRoundtripChecks.swift'),
           Path(__file__).with_name('PDFExcerptChecks.swift'),
           Path(__file__).with_name('PDFExcerptRecoveryChecks.swift'),
           Path(__file__).with_name('PDFExcerptFenceChecks.swift'),
           Path(__file__).with_name('main.swift')]
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
ios = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift')) + [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
ios += [root / 'iOSClient/IPadAudioSession.swift', root / 'iOSClient/IPadAudioLeaseState.swift',
        root / 'iOSClient/IPadAudioLeaseCoordinator.swift']
inputs = list(dict.fromkeys(sources + ios + [protocol, Path(__file__)]))
inputs += [Path(__file__).with_name('vault-roundtrip.cjs')]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
relay = Path(os.environ.get('PENCIL_RELAY_REPO', '/Users/ambrion/Documents/ChatGPT/BT_CCR-Obsidian-relay'))
relay_inputs = [relay / 'relay/obsidian-vault.js', relay / 'relay/canvas-diagram.js'] if '--vault-roundtrip' in sys.argv[2:] else []
relay_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in relay_inputs}
tool_env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
isolated = '--pdf-isolated' in sys.argv[2:]
normal_hashes = {}
plist = root / 'Tests/checks/handwriting-race/Info.plist'
if isolated:
    metadata = plistlib.loads(plist.read_bytes())
    metadata.update(CCRSourceCommit='a' * 40, CCRSourceTree='b' * 40)
    plist = output / 'fixture-source.plist'
    plist.write_bytes(plistlib.dumps(metadata))
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=tool_env, text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
           '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output.parent / 'modules'),
           '-I', str(output), str(output / 'StreamProtocol.o'),
           *map(str, sources), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
           '-Xlinker', '__info_plist', '-Xlinker', str(plist),
           '-o', str(output / 'check')]
if isolated:
    command[2:2] = ['-D', 'DEBUG']

def run(command, env, timeout):
    child = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        log, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        log, _ = child.communicate()
        print(log, end='')
        raise
    return subprocess.CompletedProcess(command, child.returncode, log)

module_command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output.parent / 'modules'),
    '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', 'StreamProtocol', str(protocol),
    '-emit-module-path', str(output / 'StreamProtocol.swiftmodule'), '-o', str(output / 'StreamProtocol.o')]
module_result = run(module_command, tool_env, 240)
(output / 'module.log').write_text(module_result.stdout)
print(module_result.stdout, end='')
compile_result = run(command, tool_env, 240) if module_result.returncode == 0 else module_result
(output / 'compile.log').write_text(compile_result.stdout)
print(compile_result.stdout, end='')
code = compile_result.returncode
if code == 0:
    home = output / 'home'
    home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    if '--vault-roundtrip' in sys.argv[2:]:
        node = shutil.which('node') if os.environ.get('PENCIL_REMOTE_FIXTURE') != '1' else 'remote-node'
        if node is None:
            raise SystemExit('기존 Node 실행 파일을 찾지 못했습니다.')
        env.update(PENCIL_NODE=node, PENCIL_RELAY_REPO=str(relay),
                   PENCIL_TEST_VAULT=str(output / 'isolated-vault'), PENCIL_FIXTURE_ID=str(uuid.uuid4()),
                   PENCIL_VAULT_HELPER=str(Path(__file__).with_name('vault-roundtrip.cjs')))
    arguments = list(sys.argv[2:])
    normal_hashes = {}
    if isolated:
        support = home / 'Library/Application Support'
        model = (root / 'iOSClient/CanvasBridge/CanvasModel.swift').read_text()
        for name in re.findall(r'case \w+ = "([^"]+)"', model.split('enum Defaults')[0]):
            file = support / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'normal user state sentinel')
            normal_hashes[str(file)] = hashlib.sha256(file.read_bytes()).hexdigest()
        identity = str(uuid.uuid4())
        context = support / 'CCRIntegrationTests' / identity
        context.mkdir(parents=True)
        (context / 'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',
            id=identity,commit='a' * 40,tree='b' * 40,relayAddress='http://192.168.45.4:8793',token='fixture-only-' + 't' * 24)))
        arguments += ['--ccr-test-runtime', identity]
    result = run([str(output / 'check'), *arguments], env, 180)
    if isolated and any(hashlib.sha256(Path(p).read_bytes()).hexdigest() != value for p,value in normal_hashes.items()):
        raise RuntimeError('격리 PDF 실행이 normal 보호 파일을 변경했습니다.')
    (output / 'runtime.log').write_text(result.stdout)
    print(result.stdout, end='')
    code = result.returncode
iphone = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], env=tool_env, text=True).strip()
ios_output = output / 'ios'
ios_output.mkdir(exist_ok=True)
ios_module = ['xcrun', 'swiftc', '-sdk', iphone, '-target', 'arm64-apple-ios27.0',
    '-swift-version', '5', '-module-cache-path', str(output.parent / 'ios-modules'),
    '-emit-module', '-module-name', 'StreamProtocol', str(protocol),
    '-emit-module-path', str(ios_output / 'StreamProtocol.swiftmodule')]
ios_check = ['xcrun', 'swiftc', '-sdk', iphone, '-target', 'arm64-apple-ios27.0',
    '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output.parent / 'ios-modules'),
    '-I', str(ios_output), '-typecheck', *map(str, ios)]
ios_result = run(ios_module, tool_env, 240)
if ios_result.returncode == 0:
    ios_result = run(ios_check, tool_env, 240)
(output / 'ios-typecheck.log').write_text(ios_result.stdout)
print(ios_result.stdout, end='')
if ios_result.returncode != 0:
    code = ios_result.returncode
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
unchanged = after == hashes
relay_unchanged = all(hashlib.sha256(p.read_bytes()).hexdigest() == relay_hashes[str(p)] for p in relay_inputs)
if not unchanged or not relay_unchanged:
    code = 1
(output / 'result.json').write_text(json.dumps({'sourceHashes': hashes, 'sourceHashesAfter': after,
    'sourceUnchanged': unchanged, 'sdk': sdk, 'command': command, 'moduleCommand': module_command,
    'iosCommand': ios_check, 'iosSDKTypecheckExit': ios_result.returncode, 'deviceExecuted': False,
    'relaySourceHashes': relay_hashes, 'relaySourceUnchanged': relay_unchanged,
    'actualVaultModuleFileRoundtrip': '--vault-roundtrip' in sys.argv[2:],
    'PNGScope': 'native PencilKit ink fixture; full scene visual parity not asserted',
    'HTTPOrOpenScreenRoundtrip': False, 'physicalPencilInput': False,
    'actualStoreIsolatedPDFRecovery': isolated, 'normalProtectedFilesUnchanged': True if isolated and code == 0 else None,
    'normalProtectedFileHashes': normal_hashes if isolated else None,
    'exitCode': code}, indent=2) + '\n')
sys.exit(code if code >= 0 else 1)

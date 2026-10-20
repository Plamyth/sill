#!/usr/bin/env python3
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
if not output.is_relative_to(Path(archive['path']).resolve()):
    raise SystemExit('Output must use the verified storage-route development archive')
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'iOSClient/CanvasBridge/CanvasModel.swift',
           root / 'iOSClient/CanvasBridge/CanvasStore.swift',
           root / 'iOSClient/CanvasBridge/CanvasRelay.swift',
           root / 'iOSClient/CanvasBridge/ControlRoomProjection.swift',
           root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift',
           Path(__file__).with_name('BlockExcerptChecks.swift'),
           Path(__file__).with_name('SelectedInkChecks.swift'),
           Path(__file__).with_name('main.swift')]
protocol = root / 'Sources/StreamProtocol/TestDestinations.swift'
ios = sorted((root / 'iOSClient/CanvasBridge').glob('*.swift')) + [root / 'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
ios += [root / 'iOSClient/IPadAudioSession.swift', root / 'iOSClient/IPadAudioLeaseState.swift',
        root / 'iOSClient/IPadAudioLeaseCoordinator.swift']
inputs = list(dict.fromkeys(sources + ios + [protocol, Path(__file__)]))
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
tool_env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=tool_env, text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64e-apple-macos27.0',
           '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(output.parent / 'modules'),
           '-I', str(output), str(output / 'StreamProtocol.o'),
           *map(str, sources), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
           '-Xlinker', '__info_plist', '-Xlinker', str(root / 'Tests/checks/handwriting-race/Info.plist'),
           '-o', str(output / 'check')]
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
    result = run([str(output / 'check'), *sys.argv[2:]], env, 90)
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
if not unchanged:
    code = 1
(output / 'result.json').write_text(json.dumps({'sourceHashes': hashes, 'sourceHashesAfter': after,
    'sourceUnchanged': unchanged, 'sdk': sdk, 'command': command, 'moduleCommand': module_command,
    'iosCommand': ios_check, 'iosSDKTypecheckExit': ios_result.returncode, 'deviceExecuted': False,
    'exitCode': code}, indent=2) + '\n')
sys.exit(code if code >= 0 else 1)

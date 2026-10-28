#!/usr/bin/env python3
"""Foundation-only extraction checks. No iOS SDK build, UI, network or real Keychain."""
import os
import re
import sys
import uuid
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
model = (root / 'iOSClient/CanvasBridge/CanvasModel.swift').read_text()
relay = (root / 'iOSClient/CanvasBridge/CanvasRelay.swift').read_text()
workspace = (root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift').read_text()
store = (root / 'iOSClient/CanvasBridge/CanvasStore.swift').read_text()
app = (root / 'iOSClient/SillApp.swift').read_text()


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def function(text, start):
    tail = text[text.index(start):]
    opening = tail.index('{')
    depth = 1
    for index in range(opening + 1, len(tail)):
        depth += (tail[index] == '{') - (tail[index] == '}')
        if depth == 0:
            return tail[:index + 1]
    raise AssertionError(start)


def check(condition, label):
    assert condition, label
    print('PASS static: ' + label, flush=True)


# These checks cover framework wiring, not a SwiftUI/SDK compile or device proof.
gate = between(app, 'switch CanvasRuntime.launch', '#else')
invalid = between(gate, 'case .invalid:', 'case .normal:')
isolated = between(gate, 'case .isolated:', 'case .invalid:')
check('Text(' in invalid and all(s not in invalid for s in ['ContentView', 'CanvasWorkspace', 'CanvasStore']),
      'invalid app entry contains only a Korean error view')
check('CanvasWorkspace()' in isolated and 'ContentView' not in isolated and 'StreamClient' not in app,
      'isolated app entry opens actual workspace without ContentView/StreamClient')
check('.onAppear {' in isolated and 'try CanvasRuntime.writeRuntimeReceipt()' in isolated and
      'catch {' in isolated and 'canvasTestRuntimeReceiptError' in isolated and
      app.count('writeRuntimeReceipt(') == 1 and 'writeRuntimeReceipt' not in invalid,
      'actual isolated workspace appearance writes receipt and surfaces Korean failure')
check('@StateObject' not in app and '#if DEBUG' in app and 'ContentView()' in app.split('#else')[1],
      'app gate has no eager store and Release keeps normal entry')
check('StreamClient()' in (root / 'iOSClient/ContentView.swift').read_text(),
      'ContentView is the StreamClient construction boundary')
for signature, file in [('private static func sceneURL()', '.scene'),
                        ('private static func outboxURL()', '.outbox')]:
    check('CanvasRuntime.stateURL(' + file in function(store, signature), signature + ' uses shared paths')
check('CanvasRuntime.stateURL(.blockRecovery,blockRecoveryOverride:blockRecoveryOverride)' in store and
      'self.blockRecoveryOverride = blockRecoveryURL' in store,
      'block recovery recomputes paths for reads, writes and conflict comparisons')
check('CanvasRuntime.stateURL(.checkpoint)' in function(workspace, 'private static func canvasVaultCheckpointURL()'),
      'checkpoint restore/save share one path')
check('if case .normal = CanvasRuntime.launch' in function(workspace, '    init()'),
      'DEBUG checkpoint legacy defaults are restricted to normal launch')
check('applicationSupportDirectory' not in store + workspace,
      'store/workspace have no remaining default path bypass')
store_init = function(store, 'init(blockRecoveryURL:')
check(store_init.index('case .invalid') < store_init.index('Self.restoreScene()'),
      'accidental invalid Store construction returns before any restore')
check('CanvasRuntime.validateStateURL(url)' in function(model, 'static func write(_ data:'),
      'atomic writes reject requested-test path escapes')
check('CanvasLocalFile.read' in function(store, 'private static func readBlockRecovery(') and
      'CanvasLocalFile.read' in function(store, 'private static func restoreScene()') and
      'CanvasLocalFile.read' in store_init and 'CanvasLocalFile.read' in function(workspace, '    init()'),
      'every persistent restore/readback uses descriptor-checked state reads')

runtime = between(model, 'enum CanvasRuntime {', 'func canvasSelectedCharacterRange')
local_file = function(model, 'enum CanvasLocalFile {')
relay_code = between(relay, '    let address: String\n', '    private func response<')
checkpoint = between(model, 'enum VaultSaveConflict:', 'enum VaultBlockRecoveryError:')
workspace_init = function(workspace, '    init()')
workspace_path = function(workspace, '    private static func canvasVaultCheckpointURL()')
standins = (here / 'Standins.swift').read_text()
scenarios = (here / 'main.swift').read_text()
check('runtime.json' not in between(model, 'enum StateFile:', '#if DEBUG'),
      'normal StateFile API never exposes runtime receipt')
receipt_helper = function(model, '    static func writeRuntimeReceipt(')
check('bundle: Bundle = .main' in receipt_helper and 'case .isolated(let context) = launch' in receipt_helper and
      'CanvasLocalFile.write' in receipt_helper and 'SHA256.hash(data:executableBytes)' in receipt_helper and
      'processID:getpid()' in receipt_helper and 'token' not in receipt_helper,
      'receipt helper uses active context, actual Bundle bytes, atomic writer and no token')
source = ('import Foundation\nimport CryptoKit\nimport Darwin\nimport CoreFoundation\n' + standins + runtime + local_file +
          '\nstruct CanvasRelay {\n' + relay_code + '\n' +
          'func checkedRequest(_ path: String) throws -> URLRequest { try request(path) }\n}\n' +
          checkpoint + '\nstruct CheckpointInitialization {\n' +
          '\n'.join('@State var ' + name + ': ' + kind + ' = ' + value for name, kind, value in [
              ('relayAddress', 'String', '"default"'), ('relayToken', 'String', '""'),
              ('vaultSceneID', 'UUID?', 'nil'), ('vaultSyncAddress', 'String?', 'nil'),
              ('syncedSceneSha', 'String?', 'nil'), ('canvasNoteSha', 'String?', 'nil'),
              ('pendingSceneSha', 'String?', 'nil'), ('canvasVaultBlocked', 'Bool', 'false'),
              ('canvasSaveConflict', 'VaultSaveConflict?', 'nil')]) + '\n' + workspace_init + '\n' +
          workspace_path + '\n}\n' + scenarios)

archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
audit = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(archive['path']) / ('context-check-' + uuid.uuid4().hex)
check(any(parent.exists() and parent.samefile(archive['path']) for parent in [audit, *audit.parents]),
      'context outputs use the verified development archive')
audit.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='ipad-context-check-', dir=audit) as temporary:
    output = Path(temporary)
    swift = output / 'main.swift'
    swift.write_text(source)
    plist = output / 'Info.plist'
    plist.write_bytes(plistlib.dumps({'CCRSourceCommit': 'a' * 40, 'CCRSourceTree': 'b' * 40}))
    executable_bytes = b'synthetic executable bytes for helper checks only\n'
    for variant, changes in [('valid', {}), ('commit', {'CCRSourceCommit': 'c' * 40}),
                             ('tree', {'CCRSourceTree': 'c' * 40}), ('identity', {'CFBundleIdentifier': ''}),
                             ('build', {'CFBundleVersion': ''}), ('executable', {})]:
        contents = output / (variant + '.bundle') / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        metadata = dict(CCRSourceCommit='a' * 40, CCRSourceTree='b' * 40,
                        CFBundleIdentifier='com.ambrion.sillcanvas.ipad.helper', CFBundleVersion='42',
                        CFBundleExecutable='HelperExecutable', CFBundlePackageType='BNDL')
        metadata.update(changes)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        if variant != 'executable':
            (contents / 'MacOS/HelperExecutable').write_bytes(executable_bytes)
    for debug in [True, False]:
        binary = output / ('debug' if debug else 'release')
        command = ['swiftc', '-swift-version', '5', '-module-cache-path', str(audit / 'ipad-test-context-modules')]
        if debug:
            command += ['-D', 'DEBUG']
        command += [str(swift), '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
                    '-Xlinker', str(plist), '-o', str(binary)]
        print('RUN ' + ' '.join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=180)
        if not debug:
            check(b'--ccr-test-runtime' not in binary.read_bytes() and
                  b'ccr.ipad-test-context/v1' not in binary.read_bytes() and
                  b'ccr.ipad-test-runtime/v1' not in binary.read_bytes() and
                  b'writeRuntimeReceipt' not in binary.read_bytes() and
                  b'runtime.json' not in binary.read_bytes(), 'Release binary omits test launch and receipt code/schema')
        for mode in ['normal', 'valid', 'invalid', 'duplicate', 'missing-context', 'unsafe-state']:
            home = output / (binary.name + '-' + mode)
            support = home / 'Library/Application Support'
            support.mkdir(parents=True)
            identity = '12345678-1234-4234-8234-123456789abc'
            context = support / 'CCRIntegrationTests' / identity
            context.mkdir(parents=True)
            payload = dict(schema='ccr.ipad-test-context/v1', id=identity,
                           commit='a' * 40, tree='b' * 40,
                           relayAddress='http://192.168.45.4:8791', token='t' * 24)
            if mode != 'missing-context':
                (context / 'context.json').write_text(json.dumps(payload))
            if mode == 'unsafe-state':
                (context / 'state').symlink_to(support, target_is_directory=True)
            # Sentinels prove the existing user files/default import remain untouched.
            for relative in re.findall(r'case \w+ = "([^"]+)"', between(model, 'enum StateFile:', 'enum Defaults')):
                file = support / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'original-state')
            documents = home / 'Documents'
            documents.mkdir()
            (documents / 'canvas-relay.json').write_text(json.dumps(dict(address=payload['relayAddress'], token=payload['token'])))
            arguments = [] if mode == 'normal' else ['--ccr-test-runtime', identity]
            if mode == 'invalid':
                arguments = ['--ccr-test-runtime', '../invalid']
            if mode == 'duplicate':
                arguments *= 2
            expected = ('isolated' if mode == 'valid' else 'invalid') if debug and mode != 'normal' else 'normal'
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), CCR_CHECK_HOME=str(home),
                       CCR_CHECK_BUNDLES=str(output), CCR_CHECK_EXECUTABLE_SHA256=hashlib.sha256(executable_bytes).hexdigest(),
                       CCR_CHECK_MODE=expected, CCR_CHECK_SUITE='1' if debug and mode == 'normal' else '0')
            print(f'RUN {binary.name} {mode} => {expected}', flush=True)
            subprocess.run([str(binary), *arguments], cwd=root, env=env, check=True, timeout=30)
            if expected != 'isolated':
                check(not (context / 'state/runtime.json').exists(),
                      f'{binary.name} {mode} never writes runtime receipt')
    print('PASS: Foundation DEBUG/Release extraction and static wiring. iOS SDK/UI/device checks NOT RUN.', flush=True)

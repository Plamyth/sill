#!/usr/bin/env python3
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
import signal
from pathlib import Path
import plistlib
import runpy
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid
import zlib
import struct

OWNER = '01a13ace-e372-7ed1-9946-149df37ee1c3'
BUNDLE = 'com.ambrion.rea.ipad-runtime'
USER_BUNDLE = 'com.ambrion.sillcanvas.ipad'
NODE = 'D29DDF60-B4C6-48DD-A75A-219C8F2A52A7'
ORIGINALS = ['CanvasScene.json', 'CanvasVaultCheckpoint.json', 'CanvasOutbox/ledger.json',
             'CanvasBlockEdit/recovery.json', 'CCR Sill/keyboard-diagnostics.json',
             'CCR Sill/microphone-diagnostics.json']
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           PATH='/Applications/Xcode.app/Contents/Developer/usr/bin:' + os.environ.get('PATH', '/usr/bin:/bin'))

class Held(ValueError):
    pass

def require(ok, reason):
    if not ok:
        raise Held(reason)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def read(path):
    return json.loads(Path(path).read_text())

def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)

def command(args, log=None, timeout=600, cwd=None):
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=ENV, capture_output=True, timeout=timeout)
    if log:
        Path(log).write_bytes(result.stdout + result.stderr)
    require(result.returncode == 0, 'command_failed:' + Path(str(args[0])).name)
    return result.stdout.decode()

def lease(config):
    grant = read(config['leaseFile'])
    require(grant.get('schema') == 'ccr.device-lease/v1' and grant.get('owner') == OWNER,
            'device_lease_owner_mismatch')
    require(grant.get('deviceUDID') == config['deviceUDID'], 'device_lease_target_mismatch')
    expires = dt.datetime.fromisoformat(grant['expiresAt'])
    require(expires.tzinfo is not None and expires > dt.datetime.now(dt.timezone.utc), 'device_lease_expired')
    require(set(['install', 'launch', 'copy', 'test']) <= set(grant.get('actions', [])), 'device_lease_actions_missing')
    require(isinstance(grant.get('handoffEvidence'), str) and grant['handoffEvidence'], 'device_handoff_missing')

def identity(config):
    repo = Path(config['repo']).resolve()
    require(not command(['git', 'status', '--porcelain'], cwd=repo).strip(), 'source_dirty')
    require(command(['git', 'branch', '--show-current'], cwd=repo).strip() == 'integration/ccr-ipad', 'source_branch_mismatch')
    commit = command(['git', 'rev-parse', 'HEAD'], cwd=repo).strip()
    tree = command(['git', 'rev-parse', 'HEAD^{tree}'], cwd=repo).strip()
    return {'commit': commit, 'tree': tree}

def device(config, args, name):
    lease(config)
    return command(['xcrun', 'devicectl', 'device', *args[:2], '--device', config['deviceUDID'], *args[2:]], name, 120)

def copy_file(config, work, source, destination, direction='from', optional=False, replace=False, bundle=BUNDLE):
    lease(config)
    args = ['xcrun', 'devicectl', 'device', 'copy', direction, '--device', config['deviceUDID'],
            '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
            '--source', str(source), '--destination', str(destination)]
    if replace:
        args += ['--remove-existing-content', 'true']
    result = subprocess.run(args, env=ENV, capture_output=True, timeout=60)
    if result.returncode and optional:
        message = (result.stdout + result.stderr).decode(errors='replace')
        require('No such file' in message or 'doesn’t exist' in message or 'does not exist' in message,
                'optional_copy_failed_without_absence')
        return False
    require(result.returncode == 0, 'device_copy_failed')
    return True

def snapshots(config, work, label):
    result = {}
    installed = work / (label + '-installed-user-app.json')
    device(config, ['info', 'apps', '--filter', 'bundleIdentifier == "' + USER_BUNDLE + '"',
                    '--json-output', str(installed)], work / (label + '-apps.log'))
    result['installedUserApp'] = read(installed).get('result')
    for relative in ORIGINALS:
        target = work / label / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        found = copy_file(config, work, 'Library/Application Support/' + relative, target, optional=True, bundle=USER_BUNDLE)
        result[relative] = sha(target.read_bytes()) if found else None
    write(work / (label + '.json'), result)
    return result

def request(server, method, path, body=None, authenticated=True):
    headers = {'x-canvas-token': server['token']} if authenticated else {}
    if body is not None:
        body = json.dumps(body, ensure_ascii=False).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(server['address'] + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

def pixel():
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\x00\xff')) + chunk(b'IEND', b'')

def fixture(scene_id):
    return {'schemaVersion': 1, 'id': scene_id, 'revision': 1, 'width': 2048, 'height': 1536,
            'drawingBase64': '', 'strokes': [], 'links': [], 'annotations': [], 'nodes': [
                {'id': NODE, 'kind': 'note', 'text': '시험 글자', 'confidence': 'confirmed',
                 'frame': {'x': 625, 'y': 600, 'width': 260, 'height': 120}, 'sourceStrokeIds': []}]}

def encode_scene(server, scene):
    encoded = subprocess.run([str(server['encoder'])], input=json.dumps(scene, ensure_ascii=False).encode(), env=ENV, capture_output=True, timeout=30)
    require(encoded.returncode == 0, 'native_scene_encoding_failed')
    return encoded.stdout

def save_scene(server, scene, image, base):
    return request(server, 'PUT', '/vault/canvas?id=' + scene['id'].lower(), {
        'revision': scene['revision'], 'sceneJSONBase64': base64.b64encode(encode_scene(server,scene)).decode(),
        'imagePNGBase64': base64.b64encode(image).decode(), 'baseSha256': base})

def runtime_readback(config, work, test_id):
    destination = work / ('runtime-readback-' + str(time.time_ns()) + '.json')
    copy_file(config, work, 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/runtime.json', destination)
    data = read(destination)
    require(data.get('schema') == 'ccr.ipad-test-runtime/v1' and data.get('id').lower() == test_id.lower(), 'runtime_context_mismatch')
    return data, destination

def stop_owned(config, work):
    test_id = read(work / 'deployment.json')['testId']
    observed, _ = runtime_readback(config, work, test_id)
    pid = observed['processID']
    processes = work / ('processes-' + str(time.time_ns()) + '.json')
    device(config, ['info', 'processes', '--json-output', str(processes)], work / 'processes.log')
    rows = read(processes)['result']['runningProcesses']
    found = [r for r in rows if r['processIdentifier'] == pid]
    if not found:
        return
    installed = read(work / 'install.json')['result']['installedApplications']
    candidates = [row for row in installed if row.get('bundleID') == BUNDLE]
    require(len(candidates) == 1 and observed.get('bundleID') == BUNDLE, 'installed_test_identity_missing')
    executable = urllib.parse.urljoin(candidates[0]['installationURL'], 'Sill')
    require(len(found) == 1 and found[0]['executable'] == executable, 'owned_process_mismatch')
    device(config, ['process', 'terminate', '--pid', str(pid)], work / 'stop.log')

def deploy(config, work, source):
    lease(config)
    previous = snapshots(config, work, 'user-before-current')
    if (work / 'user-before.json').exists():
        require(read(work / 'user-before.json') == previous, 'user_data_changed_since_previous_deploy')
    else:
        write(work / 'user-before.json', previous)
    derived = Path(config.get('buildCache', str(Path(config['outputRoot']) / 'AppDerivedData'))).resolve()
    output_root = Path(config['outputRoot']).resolve()
    require(derived.is_relative_to(output_root) and derived != output_root, 'build_cache_not_owned')
    app = derived / 'Build/Products/Debug-iphoneos/Sill.app'
    version = '1'
    metadata = plistlib.loads((Path(config['repo']) / 'iOSClient/Info-Debug.plist').read_bytes())
    metadata.update(CCRSourceCommit=source['commit'], CCRSourceTree=source['tree'],
                    CFBundleIdentifier=BUNDLE, CFBundleDisplayName='REA 통합 검증', CFBundleVersion=version)
    metadata_path = derived.parent / 'Diagnostic-Runtime-Info.plist'
    require(not metadata_path.is_symlink() and metadata_path.resolve().is_relative_to(output_root), 'metadata_path_not_owned')
    metadata_path.write_bytes(plistlib.dumps(metadata))
    fixture_writer = runpy.run_path(str(Path(config['repo']) / 'Scripts/owner-bootstrap-fixture.py'))['write_fixture']
    owner_profile = fixture_writer(derived.parent / 'OwnerBootstrapFixture')
    command(['xcodebuild', '-project', Path(config['repo']) / 'iOSClient/Sill.xcodeproj', '-scheme', 'Sill',
             '-configuration', 'Debug', '-destination', 'generic/platform=iOS', '-derivedDataPath', derived, '-allowProvisioningUpdates',
             'DEVELOPMENT_TEAM=' + config['developmentTeam'], 'CURRENT_PROJECT_VERSION=' + version,
             'PRODUCT_BUNDLE_IDENTIFIER=' + BUNDLE, 'INFOPLIST_FILE=' + str(metadata_path),
             'CCR_OWNER_MAC_BOOTSTRAP_PROFILE=' + owner_profile['path'],
             'CCR_OWNER_MAC_BOOTSTRAP_SHA256=' + owner_profile['sha256'], 'build'],
            work / 'build.log', 1200)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE, 'test_bundle_mismatch')
    require(info.get('CCRSourceCommit') == source['commit'] and info.get('CCRSourceTree') == source['tree'], 'built_metadata_mismatch')
    executable = sha((app / info['CFBundleExecutable']).read_bytes())
    command(['codesign', '--verify', '--strict', app], work / 'codesign.log')
    require(sha((app / 'CCR-OwnerMacBootstrap.json').read_bytes()) == owner_profile['sha256'], 'owner_profile_resource_mismatch')
    artifact = work / 'Artifact/Sill.app'
    artifact.parent.mkdir(exist_ok=True)
    shutil.copytree(app, artifact, dirs_exist_ok=True)
    app = artifact
    test_id = str(uuid.uuid5(uuid.NAMESPACE_URL, BUNDLE + source['commit'] + config['deviceUDID']))
    context_path = work / 'context.json'
    address = 'http://' + config['relayHost'] + ':' + str(config['relayPort'])
    context = read(context_path) if context_path.exists() else {
        'schema': 'ccr.ipad-test-context/v1', 'id': test_id, **source,
        'relayAddress': address, 'token': secrets.token_hex(32)}
    require(context['id'] == test_id and context['relayAddress'] == address and
            all(context[k] == source[k] for k in source), 'existing_context_changed')
    write(context_path, context)
    state = work / 'seed-state'
    require(not state.is_symlink() and state.resolve().parent == work.resolve(), 'seed_path_escapes_test_runtime')
    state.mkdir(exist_ok=True)
    write(state / 'CanvasScene.json', fixture(test_id))
    root = 'Library/Application Support/CCRIntegrationTests/' + test_id
    device(config, ['install', 'app', str(app), '--json-output', str(work / 'install.json')], work / 'install.log')
    copy_file(config, work, state, root + '/state', 'to', replace=True)
    copy_file(config, work, work / 'context.json', root + '/context.json', 'to')
    server, _, _ = relay_runtime(config, work, source)
    time.sleep(1)
    ready_status, _ = request(server, 'GET', '/vault/entries')
    require(ready_status == 200, 'isolated_relay_not_ready')
    device(config, ['process', 'launch', BUNDLE, '--json-output', str(work / 'launch.json'), '--', '--ccr-test-runtime', test_id], work / 'launch.log')
    time.sleep(2)
    observed, evidence = runtime_readback(config, work, test_id)
    require(all(observed.get(k) == source[k] for k in source), 'runtime_source_mismatch')
    require(observed.get('executableSHA256') == executable, 'runtime_executable_mismatch')
    require(snapshots(config, work, 'user-after-deploy') == previous, 'original_data_changed')
    result = {'status': 'applied', **source, 'runtimeId': BUNDLE + ':' + test_id + ':' + executable,
              'testId': test_id, 'executableSHA256': executable, 'sourceReadback': str(evidence), 'app': str(app)}
    write(work / 'deployment.json', result)
    stop_owned(config, work)
    return result

def run_live_harness(args, log, on_ready, timeout=180):
    with log.open('w') as output:
        process = subprocess.Popen(args, env=ENV, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        applied = False
        try:
            while process.poll() is None:
                require(time.monotonic() < deadline, 'live_rotation_ui_timeout')
                if not applied and 'CCR_ROTATION_LIVE_READY' in log.read_text():
                    on_ready()
                    applied = True
                time.sleep(0.1)
            require(process.returncode == 0 and applied, 'live_rotation_ui_or_callback_failed')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)

def harness(config, work, method, variables=None, on_ready=None):
    lease(config)
    derived = work / 'HarnessDerivedData'
    if not list((derived / 'Build/Products').glob('*.xctestrun')):
        command(['xcodebuild', '-project', Path(config['repo']) / 'Tests/integration/ipad-runtime/CanvasBridge.xcodeproj',
                 '-scheme', 'CanvasBridge', '-configuration', 'Debug', '-destination', 'id=' + config['deviceUDID'],
                 '-derivedDataPath', derived, 'DEVELOPMENT_TEAM=' + config['developmentTeam'], 'build-for-testing'],
                work / 'harness-build.log', 600)
    runs = list((derived / 'Build/Products').glob('*.xctestrun'))
    require(len(runs) == 1, 'harness_run_ambiguous')
    run = plistlib.loads(runs[0].read_bytes())
    for key, value in run.items():
        if isinstance(value, dict) and key != '__xctestrun_metadata__':
            value.setdefault('EnvironmentVariables', {})['CCR_TEST_RUNTIME_ID'] = read(work / 'deployment.json')['testId']
            value['EnvironmentVariables']['CCR_TEST_BUNDLE'] = BUNDLE
            for name in ['CCR_ROTATION_EXPECTED', 'CCR_ROTATION_DELTA']:
                value['EnvironmentVariables'].pop(name, None)
            value['EnvironmentVariables'].update(variables or {})
    runs[0].write_bytes(plistlib.dumps(run))
    result = work / (method + '-' + str(time.time_ns()) + '.xcresult')
    args = ['xcodebuild', 'test-without-building', '-xctestrun', str(runs[0]), '-destination', 'id=' + config['deviceUDID'],
            '-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/' + method, '-resultBundlePath', str(result),
            '-parallel-testing-enabled', 'NO']
    log = work / (method + '.log')
    if on_ready is None:
        command(args, log, 180)
    else:
        run_live_harness(args, log, on_ready)
    return result

def strict_canvas_png(data):
    try:
        require(data[:8] == b'\x89PNG\r\n\x1a\n', 'png_signature')
        position=8; kinds=[]; parts=[]; header=None; idat_ended=False
        while position < len(data):
            require(position+12 <= len(data), 'png_chunk_header')
            size=struct.unpack('>I',data[position:position+4])[0]
            require(size <= len(data)-position-12, 'png_chunk_length')
            kind=data[position+4:position+8]; body=data[position+8:position+8+size]
            crc=struct.unpack('>I',data[position+8+size:position+12+size])[0]
            require(zlib.crc32(kind+body) == crc, 'png_crc')
            require(kinds or kind == b'IHDR', 'png_first_chunk')
            if kind == b'IHDR':
                require(not kinds and size == 13, 'png_header')
                header=struct.unpack('>IIBBBBB',body)
            elif kind == b'IDAT':
                require(header is not None and not idat_ended, 'png_idat_sequence')
                parts.append(body)
            elif parts:
                idat_ended=True
            require(kind in [b'IHDR',b'PLTE',b'IDAT',b'IEND'] or kind[0]&32, 'png_unknown_critical')
            kinds.append(kind);position+=size+12
            if kind == b'IEND':
                require(size == 0 and position == len(data), 'png_end')
        require(header and kinds[-1] == b'IEND' and parts, 'png_incomplete')
        width,height,depth,color,compression,filtering,interlace=header
        require(2048 <= width <= 8192 and 1536 <= height <= 8192 and width*1536 == height*2048,
                'png_dimensions')
        require(depth == 8 and color in [2,6] and compression == filtering == interlace == 0, 'png_pixel_format')
        row=1+width*(3 if color == 2 else 4);expected=row*height
        stream=zlib.decompressobj(); raw=stream.decompress(b''.join(parts),expected+1)
        require(stream.eof and not stream.unused_data and not stream.unconsumed_tail and len(raw) == expected,
                'png_deflate_incomplete')
        require(all(raw[y*row] <= 4 for y in range(height)), 'png_filter')
        return True
    except (Held, ValueError, IndexError, struct.error, zlib.error):
        return False

def valid_canvas_png(data, scene, encoder):
    if not strict_canvas_png(data):
        return False
    try:
        result = subprocess.run([str(encoder),'--check-rotation-pixels'],
            input=json.dumps({'image':base64.b64encode(data).decode(),'scene':scene}).encode(),
            env=ENV,capture_output=True,timeout=30)
        return result.returncode == 0 and json.loads(result.stdout).get('valid') is True
    except (OSError, ValueError, subprocess.SubprocessError):
        return False

def accept_rotation(config, work, server, vault, test_id):
    code, prior = request(server, 'GET', '/vault/canvas?id=' + test_id)
    require(code == 200, 'rotation_seed_lookup_failed')
    start = fixture(test_id)
    start['revision'] = prior['revision'] + 1
    start['nodes'][0]['text'] = '회전 검사'
    second = '42478F2C-F81D-4AC9-B714-ECBD9DDAC411'
    start['nodes'].append(dict(start['nodes'][0], id=second, text='연결 대상',
                              frame={'x':1050,'y':1000,'width':260,'height':120}))
    start['links'] = [{'id':'8FBAA143-E660-4E64-8EC1-3B20CE1E2DF9','from':NODE,'to':second,
                      'label':'회전 추종','fromAnchor':{'side':'right','offset':0.5},
                      'toAnchor':{'side':'left','offset':0.5}}]
    start = json.loads(encode_scene(server,start))
    code, _ = save_scene(server, start, pixel(), prior['noteSha256'])
    require(code == 200, 'rotation_seed_failed')
    stop_owned(config, work)
    seed = work / 'rotation-state'; seed.mkdir(exist_ok=True)
    write(seed / 'CanvasScene.json', start)
    copy_file(config, work, seed, 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state', 'to', replace=True)
    rotated_ui = harness(config, work, 'testRotateAndSave')
    def rotated(expected):
        deadline = time.monotonic() + 20
        while True:
            code, value = request(server, 'GET', '/vault/canvas?id=' + test_id)
            require(code == 200, 'rotation_vault_lookup_failed')
            scene = json.loads(base64.b64decode(value['sceneJSONBase64']))
            if abs(scene['nodes'][0].get('rotationDegrees',0)-expected) < 1:
                return value, scene
            require(time.monotonic() < deadline, 'rotation_not_saved')
            time.sleep(0.2)
    saved, actual = rotated(45)
    angle = actual['nodes'][0]['rotationDegrees']
    preserved = json.loads(json.dumps(actual))
    preserved['revision'] = start['revision']; preserved['nodes'][0].pop('rotationDegrees', None)
    require(preserved == start, 'rotation_changed_unrelated_scene_data')
    assets = vault / 'CCR Canvas/Assets'
    image = next((p for p in assets.iterdir() if sha(p.read_bytes()) == saved['imageSha256']), None)
    require(image is not None and image.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n' and
            valid_canvas_png(image.read_bytes(),actual,server['encoder']), 'rotation_native_png_missing')
    require(sha((vault / saved['path']).read_bytes()) == saved['noteSha256'], 'rotation_markdown_hash_mismatch')
    rendered = work / 'rotation-rendered-45.png'; shutil.copyfile(image,rendered)
    reopen = harness(config, work, 'testReopenRotatedScene', {'CCR_ROTATION_EXPECTED':'45'})
    native90 = harness(config, work, 'testRotateAndSave', {'CCR_ROTATION_EXPECTED':'90','CCR_ROTATION_DELTA':'45'})
    right_angle, scene90 = rotated(90)
    image90 = next((p for p in assets.iterdir() if sha(p.read_bytes()) == right_angle['imageSha256']), None)
    require(image90 is not None and valid_canvas_png(image90.read_bytes(),scene90,server['encoder']), 'rotation_90_native_png_missing')
    rendered90 = work / 'rotation-rendered-90.png'; shutil.copyfile(image90,rendered90)
    restore45 = harness(config, work, 'testRotateAndSave', {'CCR_ROTATION_EXPECTED':'45','CCR_ROTATION_DELTA':'-45'})
    saved, actual = rotated(45)
    remote = json.loads(json.dumps(actual)); remote['revision'] += 1
    remote['nodes'][0]['rotationDegrees'] = 90
    def apply_remote():
        status, _ = save_scene(server, remote, rendered90.read_bytes(), saved['noteSha256'])
        require(status == 200, 'rotation_remote_update_failed')
    live = harness(config, work, 'testLiveRotatedRemoteRevision', on_ready=apply_remote)
    final_reopen = harness(config, work, 'testReopenRotatedScene', {'CCR_ROTATION_EXPECTED':'90'})
    code, final = request(server, 'GET', '/vault/canvas?id=' + test_id)
    require(code == 200 and json.loads(base64.b64decode(final['sceneJSONBase64'])) == remote,
            'rotation_reverse_scene_mismatch')
    local = work / 'rotation-device-scene.json'
    copy_file(config, work, 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/CanvasScene.json', local)
    require(read(local) == remote, 'rotation_reverse_device_mismatch')
    proof = {'ui':str(rotated_ui),'reopen':str(reopen),'live':str(live),'finalReopen':str(final_reopen),
             'native90':str(native90),'restore45':str(restore45),
             'localRotation':angle,'remoteRotation':90,'scene':actual,'reverseScene':remote,
             'renderedImage':str(rendered),'remoteRenderedImage':str(rendered90),
             'remotePNGSource':'실제 iPad의 같은 노드·내용·90도 장면을 production SceneRenderer로 렌더링',
             'vault':saved,'finalVault':final,'deviceScene':str(local)}
    write(work / 'rotation-functional-readback.json', proof)
    return proof

def relay_runtime(config, work, source):
    relay_repo = Path(config['relayRepo']).resolve()
    require(command(['git', 'rev-parse', 'HEAD'], cwd=relay_repo).strip() == config['relayCommit'], 'relay_source_mismatch')
    require(not command(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=relay_repo).strip(), 'relay_source_dirty')
    vault = work / 'isolated-vault'
    require(not vault.is_symlink() and vault.resolve().parent == work.resolve(), 'vault_path_escapes_test_runtime')
    vault.mkdir(exist_ok=True)
    snapshot = work / 'snapshot.json'; hidden = work / 'hidden.json'; write(snapshot, {}); write(hidden, [])
    encoder = work / 'NativeSceneEncoder'
    command(['xcrun', 'swiftc', '-parse-as-library', Path(config['repo']) / 'iOSClient/CanvasBridge/CanvasModel.swift',
             Path(config['repo']) / 'Scripts/ipad-test-runtime/NativeSceneEncoder.swift', '-o', encoder], work / 'scene-encoder-build.log')
    ctx = read(work / 'context.json'); server = {'token': ctx['token'], 'address': ctx['relayAddress'], 'encoder': encoder}
    conf = {'relayRepo': str(relay_repo), 'vault': str(vault), 'store': str(work / 'relay-store'),
            'snapshot': str(snapshot), 'hidden': str(hidden), 'token': ctx['token'], 'host': config['relayHost'], 'port': config['relayPort']}
    write(work / 'relay-private.json', conf)
    lifecycle = '/Users/ambrion/.local/bin/bt-service-lifecycle'
    previous = work / 'relay-lease.json'
    service = None
    policy = runpy.run_path(lifecycle)
    if previous.exists() and not (work / 'relay-release.json').exists():
        prior = read(previous)
        require(prior['owner'] == OWNER and prior['generation'] == source['commit'], 'relay_lease_identity_mismatch')
        authoritative = policy['LEASES'] / (prior['leaseId'] + '.json')
        if authoritative.exists():
            current = read(authoritative)
            require(all(current.get(k) == prior.get(k) for k in ['leaseId','owner','serviceId','generation','pid','birth']),
                    'relay_authoritative_identity_mismatch')
            expiry = policy['expiry'](current)
            require(expiry is not None, 'relay_expiry_invalid')
            if policy['is_live'](current) and expiry > policy['now']():
                try:
                    service = json.loads(command([lifecycle, 'renew', '--owner', OWNER, '--ttl', '900', prior['leaseId']], work / 'relay-renew.log'))
                except Held:
                    require(not policy['is_live'](current) or expiry <= policy['now'](), 'relay_renew_failed_while_live')
            if service is None:
                released = json.loads(command([lifecycle, 'release', '--owner', OWNER, prior['leaseId']], work / 'relay-stale-release.log'))
                require(released.get('released') is True, 'stale_relay_release_unconfirmed')
                write(work / 'relay-stale-reconciliation.json', {'priorLeaseId': prior['leaseId'], 'released': True})
        else:
            require(not policy['is_live'](prior), 'orphan_owned_relay_still_live')
            write(work / 'relay-stale-reconciliation.json', {'priorLeaseId': prior['leaseId'], 'ownedProcessAbsent': True})
    if service is None:
        service = json.loads(command([lifecycle, 'start', '--owner', OWNER, '--ttl', '900',
            '--generation', source['commit'], '--stdout', work / 'isolated-relay.log',
            '--stderr', work / 'isolated-relay.err.log', 'ccr-ipad-integration-relay-8793', '--',
            config['nodeExecutable'], Path(config['repo']) / 'Scripts/ipad-test-runtime/relay.js', work / 'relay-private.json']))
        (work / 'relay-release.json').unlink(missing_ok=True)
    write(work / 'relay-lease.json', service)
    return server, vault, service

def cleanup(config, work, service, vault, test_id, before):
    lifecycle = '/Users/ambrion/.local/bin/bt-service-lifecycle'
    results = {}
    try:
        released = json.loads(command([lifecycle, 'release', '--owner', OWNER, service['leaseId']], work / 'relay-release.log'))
        require(released.get('released') is True, 'relay_lease_release_unconfirmed')
        write(work / 'relay-release.json', released)
        results['relayReleased'] = True
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['relayReleased'] = False
    try:
        stop_owned(config, work)
        results['testProcessStopped'] = True
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['testProcessStopped'] = False
    try:
        require(results['testProcessStopped'], 'test_process_not_stopped')
        empty = work / 'empty-state'; empty.mkdir(exist_ok=True)
        lease(config)
        try:
            command(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', config['deviceUDID'], '--domain-type', 'appDataContainer',
                     '--domain-identifier', BUNDLE, '--source', empty, '--destination', 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state',
                     '--remove-existing-content', 'true'], work / 'reset.log', 60)
        except Held:
            pass
        inventory = work / ('reset-device-files-' + str(time.time_ns()) + '.json')
        device(config, ['info', 'files', '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                        '--json-output', str(inventory)], work / 'reset-inventory.log')
        observed = read(inventory)['result']
        require(observed['domainIdentifier'] == BUNDLE, 'device_reset_domain_mismatch')
        prefix = 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state'
        require(not any(row['relativePath'].startswith(prefix + '/') or
                        row['relativePath'] == prefix and not row['resources']['isDirectory']
                        for row in observed['files']), 'device_fixture_reset_failed')
        results['deviceStateEmpty'] = True
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['deviceStateEmpty'] = False
    try:
        require(results['relayReleased'] and not vault.is_symlink() and vault.resolve().parent == work.resolve(), 'vault_cleanup_not_owned')
        shutil.rmtree(vault); vault.mkdir()
        results['vaultEmpty'] = not list(vault.iterdir())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['vaultEmpty'] = False
    try:
        results['originalDataPreserved'] = snapshots(config, work, 'user-after-reset') == before
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['originalDataPreserved'] = False
    write(work / 'reset-readback.json', results)
    return all(results.values())

def accept(config, work, source):
    lease(config)
    contract = acceptance_contract(config)
    deployed = read(work / 'deployment.json')
    require(all(deployed[k] == source[k] for k in source), 'deployment_source_mismatch')
    test_id = deployed['testId']; before = read(work / 'user-before.json')
    server, vault, service = relay_runtime(config, work, source)
    lifecycle = '/Users/ambrion/.local/bin/bt-service-lifecycle'
    accepted = False
    try:
        time.sleep(1)
        start = fixture(test_id)
        prior_status, prior = request(server, 'GET', '/vault/canvas?id=' + test_id)
        require(prior_status in (200, 404), 'fixture_lookup_failed')
        base = prior['noteSha256'] if prior_status == 200 else None
        if prior_status == 200:
            start['revision'] = prior['revision'] + 1
        code, saved = save_scene(server, start, pixel(), base); require(code == 200, 'fixture_seed_failed')
        write(work / 'seed-state/CanvasScene.json', start)
        copy_file(config, work, work / 'seed-state',
                  'Library/Application Support/CCRIntegrationTests/' + test_id + '/state', 'to', replace=True)
        copy_file(config, work, work / 'context.json',
                  'Library/Application Support/CCRIntegrationTests/' + test_id + '/context.json', 'to')
        ui = harness(config, work, 'testEditAndSave')
        code, current = request(server, 'GET', '/vault/canvas?id=' + test_id); require(code == 200, 'vault_readback_failed')
        actual = json.loads(base64.b64decode(current['sceneJSONBase64'])); require(actual['nodes'][0]['text'] == '👩🏽‍💻 앞 ', 'native_save_text_mismatch')
        require(actual['nodes'][0]['id'] == NODE and not actual['strokes'], 'fixture_lineage_mismatch')
        copy_file(config, work, 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/CanvasScene.json', work / 'device-scene.json')
        require(read(work / 'device-scene.json') == actual, 'device_vault_scene_mismatch')
        note = vault / current['path']; require(sha(note.read_bytes()) == current['noteSha256'], 'note_hash_mismatch')
        assets = list((vault / 'CCR Canvas/Assets').iterdir())
        require(all(any(sha(p.read_bytes()) == current[k] for p in assets) for k in ['sceneSha256', 'imageSha256']), 'asset_hash_mismatch')
        code, _ = request(server, 'GET', '/vault/entries', authenticated=False); require(code == 401, 'unauth_contract_failed')
        code, _ = save_scene(server, start, pixel(), '0' * 64); require(code == 409, 'stale_contract_failed')
        actual['revision'] += 1; actual['nodes'][0]['text'] = 'Mac에서 수정한 시험 글자'
        code, _ = save_scene(server, actual, pixel(), current['noteSha256']); require(code == 200, 'reverse_update_failed')
        command([lifecycle, 'renew', '--owner', OWNER, '--ttl', '900', service['leaseId']], work / 'relay-renew.log')
        reverse = harness(config, work, 'testReopenRemoteRevision')
        rotation = accept_rotation(config, work, server, vault, test_id)
        require(snapshots(config, work, 'user-after-accept') == before, 'original_data_changed')
        observed, runtime_evidence = runtime_readback(config, work, test_id)
        require(all(observed.get(k) == source[k] for k in source) and observed.get('executableSHA256') == deployed['executableSHA256'], 'accepted_runtime_mismatch')
        proof = {'nativeResult': str(ui), 'reverseResult': str(reverse), 'vault': current, 'runtime': observed,
                 'rotation':rotation, 'originalPreserved': True}
        write(work / 'functional-readback.json', proof)
        accepted = True
    finally:
        cleanup_passed = cleanup(config, work, service, vault, test_id, before)
    require(accepted and cleanup_passed, 'acceptance_or_cleanup_incomplete')
    evidence_path = work / 'functional-readback.json'
    evidence = {'path': str(evidence_path), 'sha256': sha(evidence_path.read_bytes())}
    reset_path = work / 'reset-readback.json'
    reset_evidence = {'path': str(reset_path), 'sha256': sha(reset_path.read_bytes())}
    checks = {k: {'status': 'pass', 'evidence': [evidence, reset_evidence]} for k in read(Path(config['repo']) / 'Scripts/ipad-test-runtime/descriptor.json')['requiredChecks']}
    receipt = {'schema': 'bt.test-acceptance/v1', 'projectId': 'bt-ccr-ipad', **source, 'runtimeId': deployed['runtimeId'],
               'environment': 'isolated-ipad-canvas', 'externalEffects': 'zero', 'contractSha256': contract,
               'isolation': {'dbIdentity': 'files:' + str(vault), 'storageIdentity': str(vault), 'providerMode': 'delivery-disabled-local-vault'},
               'fixtureReset': {'status': 'pass'}, 'checks': checks}
    require(acceptance_contract(config) == contract, 'registry_contract_changed_during_acceptance')
    write(work / 'acceptance.json', receipt)
    return {'status': 'accepted', **source, 'evidence': str(work / 'acceptance.json')}

def acceptance_contract(config):
    registry = read(Path.home() / '.config/release-convergence/projects.json')
    rows = [r for r in registry['projects'] if r['id'] == 'bt-ccr-ipad']
    require(len(rows) == 1 and rows[0].get('mode') == 'managed', 'registry_not_managed')
    test = rows[0].get('test', {})
    descriptor = read(Path(config['repo']) / 'Scripts/ipad-test-runtime/descriptor.json')
    require(sorted(set(test.get('requiredChecks', []))) == sorted(descriptor['requiredChecks']) and
            test.get('environment') == 'isolated-ipad-canvas' and test.get('externalEffects') == 'zero', 'registry_test_contract_mismatch')
    return runpy.run_path('/Users/ambrion/.local/bin/bt-release-convergence')['acceptance_contract'](rows[0])

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('phase', choices=['deploy', 'accept']); parser.add_argument('--config', required=True)
    args = parser.parse_args()
    try:
        config = read(args.config)
        output = Path(config['outputRoot']).resolve()
        approved = Path(json.loads(command(['/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad']))['path']).resolve()
        require(output.is_relative_to(approved) and output != approved, 'output_path_not_routed')
        require(ipaddress.ip_address(config['relayHost']).is_private and ipaddress.ip_address(config['relayHost']).version == 4,
                'relay_host_not_private_ipv4')
        require(int(config['relayPort']) == 8793, 'relay_port_not_registered_integration_port')
        source = identity(config); work = output / source['commit']
        require(not work.is_symlink() and work.resolve().parent == output, 'work_path_escapes_routed_root')
        work.mkdir(parents=True, exist_ok=True)
        output.mkdir(parents=True, exist_ok=True)
        with (output / 'device-and-build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lease(config)
            guard = command(['/Users/ambrion/.local/bin/codex-source-guard', 'capture', '--repo', config['repo'], '--ref', 'integration/ccr-ipad'])
            guard_data = json.loads(guard)
            require(guard_data.get('repository') == 'github.com/plamyth/sill' and
                    all(guard_data.get(k) == source[k] for k in source), 'source_guard_identity_mismatch')
            write(work / 'source-guard.json', guard_data)
            result = deploy(config, work, source) if args.phase == 'deploy' else accept(config, work, source)
            require(identity(config) == source, 'source_changed_during_run')
            print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'held', 'reason': str(error) if isinstance(error, Held) else type(error).__name__}))
        return 2
    return 0

if __name__ == '__main__':
    sys.exit(main())

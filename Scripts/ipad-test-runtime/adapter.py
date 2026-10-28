#!/usr/bin/env python3
import argparse
import base64
import datetime as dt
import fcntl
import fnmatch
import hashlib
import ipaddress
import json
import os
import signal
from pathlib import Path
import plistlib
import re
import runpy
import secrets
import shlex
import tempfile
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
NORMAL_TEAM = 'ZPTXHJ866D'
RUNNER_BUNDLE = 'com.ambrion.rea.appaudit.UITests.xctrunner'
RUNNER_CORE_METHODS = ['testEditAndSave','testReopenRemoteRevision','testRotateAndSave','testReopenRotatedScene',
        'testLiveRotatedRemoteRevision','testCommentSave','testCommentReopen','testStaleCommentDraftRequiresExplicitDiscard',
        'testRulerToggleAcrossDrawingAndSelection','testReviewEditDraftPreserved','testReviewSaveDraft','testReviewReopen',
        'testReviewLiveRemoteRevision','testReviewGood','testReviewStaleSessionRejected','testReviewMissingSourceRejected']
APPROVED_OWNER_PROFILE_SHA256 = '7bcf8ce74bf4292d1a20b07d45bfa0c040957e1ade3d80dd4be37c5eb96cf8c7'
SINGLE_APP_BLOCKERS = (
    'latest_normal_candidate_preservation_readback_required',
    'installed_build_version_and_keychain_entitlements_not_read_back',
    'install_candidate_still_uses_synthetic_owner_bootstrap',
    'installed_runner_identity_receipt_and_normal_launch_return_required',
)
NODE = 'D29DDF60-B4C6-48DD-A75A-219C8F2A52A7'
ORIGINALS = ['CanvasScene.json', 'CanvasVaultCheckpoint.json', 'CanvasOutbox/ledger.json',
             'CanvasBlockEdit/recovery.json', 'CanvasNoteEdit/recovery.json',
             'CanvasLegacyScene.json', 'CanvasWorkspace/bookmark.json', 'CCR Sill/keyboard-diagnostics.json',
             'CCR Sill/microphone-diagnostics.json']
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           PATH='/Applications/Xcode.app/Contents/Developer/usr/bin:' + os.environ.get('PATH', '/usr/bin:/bin'))

class Held(ValueError):
    pass

def require(ok, reason):
    if not ok:
        raise Held(reason)

def single_app_installation_gate():
    raise Held('single_app_runtime_held:' + ','.join(SINGLE_APP_BLOCKERS))

def destination_artifacts_run(payload, runner, test_id, variables=None):
    require(runner.get('schema') == 'ccr.existing-xctest-runner/v1' and
            runner.get('installed') is True and runner.get('team') == NORMAL_TEAM,
            'existing_runner_identity_required')
    identifier = runner.get('bundleIdentifier')
    require(identifier == 'com.ambrion.rea.appaudit.UITests.xctrunner', 'existing_runner_bundle_mismatch')
    require(runner.get('testBundleRelativePath') == '__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest',
            'existing_runner_test_bundle_mismatch')
    require(str(uuid.UUID(test_id)) == test_id.lower(), 'runtime_uuid_invalid')
    run = plistlib.loads(plistlib.dumps(payload))
    if 'TestConfigurations' in run:
        configs = run['TestConfigurations']
        require(isinstance(configs, list) and len(configs) == 1 and isinstance(configs[0], dict) and
                configs[0].get('IsEnabled', True),
                'existing_runner_configuration_ambiguous')
        targets = configs[0].get('TestTargets', [])
    else:
        targets = [value for key, value in run.items() if key != '__xctestrun_metadata__']
    require(len(targets) == 1 and isinstance(targets[0], dict), 'existing_runner_target_ambiguous')
    target = targets[0]
    require(target.get('IsUITestBundle') is True, 'existing_runner_not_ui_test')
    for field in ['TestHostPath', 'TestBundlePath', 'UITargetAppPath', 'DependentProductPaths']:
        target.pop(field, None)
    target.update(UseDestinationArtifacts=True, TestHostBundleIdentifier=identifier,
        TestBundleDestinationRelativePath=runner['testBundleRelativePath'],
        UITargetAppBundleIdentifier=USER_BUNDLE, ParallelizationEnabled=False,
        UITargetAppCommandLineArguments=['--ccr-test-runtime', test_id])
    environment = target.setdefault('EnvironmentVariables', {})
    for key in list(environment):
        if key.startswith('CCR_'):
            del environment[key]
    require(all(key.startswith(('CCR_REVIEW_', 'CCR_ROTATION_', 'CCR_COMMENT_')) and isinstance(value, str)
                for key, value in (variables or {}).items()), 'runner_environment_not_allowed')
    environment.update(variables or {}, CCR_TEST_RUNTIME_ID=test_id, CCR_TEST_BUNDLE=USER_BUNDLE)
    return run

def owner_bootstrap_identity(config):
    supplied = Path(config['ownerBootstrapProfile']).absolute()
    require(not supplied.is_symlink() and supplied.is_file(), 'owner_profile_path_invalid')
    profile = supplied.resolve()
    expected = config['ownerBootstrapSHA256']
    require(isinstance(expected, str) and re.fullmatch('[0-9a-f]{64}', expected), 'owner_profile_hash_required')
    data = profile.read_bytes()
    require(sha(data) == expected, 'owner_profile_hash_mismatch')
    validate = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'provision-owner-bootstrap.py'))['validate']
    validate(data)
    return {'path': str(profile), 'sha256': expected, 'schemaValidated': True,
            'installed': False, 'hostIdentityAccepted': False}

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
    if args[:2] == ['install', 'app']:
        single_app_installation_gate()
    lease(config)
    return command(['xcrun', 'devicectl', 'device', *args[:2], '--device', config['deviceUDID'], *args[2:]], name, 120)

def copy_file(config, work, source, destination, direction='from', optional=False, replace=False, bundle=None):
    bundle = bundle or config.get('_runtimeBundle', BUNDLE)
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
    for relative in ['Documents', 'Library/Preferences']:
        target = work / label / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        found = copy_file(config, work, relative, target, optional=True, bundle=USER_BUNDLE)
        if not found:
            result[relative] = None
            continue
        require(target.is_dir() and not target.is_symlink(), 'protected_snapshot_not_directory')
        result[relative] = {}
        target.chmod(0o700)
        for item in sorted(target.rglob('*')):
            require(not item.is_symlink(), 'protected_snapshot_symlink')
            key = str(item.relative_to(target))
            if item.is_file():
                item.chmod(0o600)
                result[relative][key] = sha(item.read_bytes())
            else:
                require(item.is_dir(), 'protected_snapshot_non_regular')
                result[relative][key + '/'] = None
    write(work / (label + '.json'), result)
    return result

def same_user_data(before, after):
    return ({key: value for key, value in before.items() if key != 'installedUserApp'} ==
            {key: value for key, value in after.items() if key != 'installedUserApp'})

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

def runtime_readback(config, work, test_id, bundle=None, optional=False):
    destination = work / ('runtime-readback-' + str(time.time_ns()) + '.json')
    found = copy_file(config, work, 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/runtime.json', destination,
                      bundle=bundle, optional=optional)
    if not found:
        return None, destination
    data = read(destination)
    require(data.get('schema') == 'ccr.ipad-test-runtime/v1' and isinstance(data.get('id'),str) and data['id'].lower() == test_id.lower(), 'runtime_context_mismatch')
    return data, destination

def artifact_code_images(files, executable):
    require(isinstance(executable,str) and re.fullmatch('[A-Za-z0-9_.-]+',executable) and executable in files,
            'prepared_code_image_executable_missing')
    names = [executable] + ([executable + '.debug.dylib'] if executable + '.debug.dylib' in files else [])
    return {name:files[name] for name in names}

def validate_runtime_code_images(runtime, expected, installation_url):
    require(runtime.get('codeImages') == expected, 'runtime_code_images_missing_or_mismatched')
    uuids = runtime.get('codeImageUUIDs')
    require(isinstance(uuids,dict) and set(uuids) == set(expected) and
            all(isinstance(value,str) and re.fullmatch('[0-9a-f]{32}',value) for value in uuids.values()),
            'runtime_code_images_uuid_binding_required')
    paths = runtime.get('loadedCodeImagePaths')
    require(isinstance(paths,dict) and set(paths) == set(expected), 'runtime_code_images_loaded_paths_missing')
    root = urllib.parse.unquote(urllib.parse.urlsplit(installation_url).path).rstrip('/')
    def normalized(path):
        require(isinstance(path,str) and path.startswith('/') and not any(p in ['.','..'] for p in path.split('/')),
                'runtime_code_images_loaded_path_invalid')
        return path.removeprefix('/private') if path.startswith('/private/var/') else path
    require(all(normalized(paths[name]) == normalized(root + '/' + name) for name in expected),
            'runtime_code_images_loaded_path_mismatch')


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r'\d+(?:\.\d+){0,2}', value), 'normal_build_version_invalid')
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))

def artifact_files(app):
    require(app.is_dir() and not app.is_symlink(), 'prepared_artifact_not_directory')
    files = {}
    for item in sorted(app.rglob('*')):
        require(not item.is_symlink(), 'prepared_artifact_symlink')
        if item.is_file():
            files[str(item.relative_to(app))] = sha(item.read_bytes())
        else:
            require(item.is_dir(), 'prepared_artifact_non_regular')
    require(files, 'prepared_artifact_empty')
    return files

def digest_value(value):
    return sha(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())

def pinned_json(config, path_key, hash_key):
    path = Path(config[path_key]).resolve()
    data = path.read_bytes()
    require(sha(data) == config[hash_key], path_key + '_changed')
    value = json.loads(data)
    require(isinstance(value, dict), path_key + '_invalid')
    return value

def install_attempt(work, value):
    path = work / 'prepared-install-attempt.json'
    write(path, value)
    with path.open('rb') as stream:
        os.fsync(stream.fileno())
    fd = os.open(work, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def installed_app(snapshot, bundle):
    result = snapshot.get('installedUserApp') or {}
    rows = result.get('apps', [])
    matches = [row for row in rows if row.get('bundleIdentifier') == bundle]
    require(len(rows) == 1 and len(matches) == 1 and matches[0].get('containerAccessible') is True,
            'installed_normal_identity_missing')
    version_tuple(matches[0].get('bundleVersion'))
    return matches[0]

def installed_normal(snapshot):
    return installed_app(snapshot, USER_BUNDLE)

def signed_entitlements(app, work, label, bundle=USER_BUNDLE):
    requirement = '=anchor apple generic and identifier "' + bundle + '" and certificate leaf[subject.OU] = "' + NORMAL_TEAM + '"'
    command(['codesign', '--verify', '--deep', '--strict', '--test-requirement', requirement, app], work / (label + '-verify.log'))
    log = work / (label + '-signature.log')
    command(['codesign', '--display', '--verbose=4', app], log)
    signing = log.read_text()
    require(re.search(r'^TeamIdentifier=' + NORMAL_TEAM + r'$', signing, re.M) and
            re.search(r'^Identifier=' + re.escape(bundle) + r'$', signing, re.M) and
            'Signature=adhoc' not in signing, label + '_codesign_identity_mismatch')
    entitlements = plistlib.loads(command(['codesign', '--display', '--entitlements', ':-', app]).encode())
    require(entitlements.get('com.apple.developer.team-identifier') == NORMAL_TEAM and
            entitlements.get('application-identifier') == NORMAL_TEAM + '.' + bundle,
            label + '_entitlements_identity_mismatch')
    return entitlements

def lineage_inputs(reference):
    require(reference.get('schema') == 'ccr.known-installed-artifact/v1', 'known_installed_lineage_required')
    artifact = Path(reference['artifact']).resolve()
    require(digest_value(artifact_files(artifact)) == reference['artifactManifestSHA256'], 'known_installed_artifact_changed')
    return artifact, [pinned_json(reference, key, digest) for key, digest in [
        ('signingReadbackPath', 'signingReadbackSHA256'), ('installRecordPath', 'installRecordSHA256'),
        ('metadataPath', 'metadataSHA256')]]

def known_installed_lineage(config, work):
    reference = pinned_json(config, 'installedIdentityReceipt', 'installedIdentityReceiptSHA256')
    return verify_known_lineage(config, work, reference, USER_BUNDLE)

def verify_known_lineage(config, work, reference, bundle):
    kind = reference.get('installEvidenceKind', 'devicectl')
    if kind == 'xcode-xcresult':
        return verify_xcode_runner_lineage(config, work, reference, bundle)
    require(kind == 'devicectl', 'known_installed_evidence_kind_unknown')
    artifact, (record, install, metadata) = lineage_inputs(reference)
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    keys = ['CFBundleIdentifier','CFBundleVersion'] + (['CCRSourceCommit','CCRSourceTree','CCRSourceIdentityVerified'] if bundle == USER_BUNDLE else [])
    require(info.get('CFBundleIdentifier') == bundle and record.get('signatureValid') is True and
            all(info.get(key) == record.get(key) for key in keys), 'known_installed_info_mismatch')
    executable = info.get('CFBundleExecutable', '')
    require(re.fullmatch('[A-Za-z0-9_.-]+', executable) and
            sha((artifact / executable).read_bytes()) == record.get('executableSHA256'), 'known_installed_readback_mismatch')
    if bundle == USER_BUNDLE:
        require(info.get('CCRSourceIdentityVerified') is True and
                all(re.fullmatch('[0-9a-f]{40}',str(info.get(key,''))) for key in ['CCRSourceCommit','CCRSourceTree']),
                'known_installed_source_identity_missing')
        require(sha((artifact / 'CCR-OwnerMacBootstrap.json').read_bytes()) == record.get('bootstrapSHA256') ==
                APPROVED_OWNER_PROFILE_SHA256, 'known_installed_profile_mismatch')
    entitlements = signed_entitlements(artifact, work, 'known-installed-' + bundle.rsplit('.', 1)[-1], bundle)
    require(entitlements == record.get('entitlements'), 'known_installed_entitlements_changed')
    args = install.get('info', {}).get('arguments', [])
    require(isinstance(args,list) and all(isinstance(arg,str) for arg in args) and
            install.get('info', {}).get('outcome') == 'success' and args[:4] == ['devicectl','device','install','app'] and
            '--device' in args and args.index('--device') + 1 < len(args) and
            args[args.index('--device') + 1] == config['deviceUDID'] and
            [Path(arg).resolve() for arg in args if arg.endswith('.app')] == [artifact],
            'known_installed_command_mismatch')
    rows = install.get('result', {}).get('installedApplications', [])
    row = installed_app({'installedUserApp':metadata.get('result')}, bundle)
    require(len(rows) == 1 and rows[0].get('bundleID') == bundle and
            rows[0].get('installationURL') == row.get('url') and row['bundleVersion'] == info['CFBundleVersion'],
            'known_installed_metadata_mismatch')
    return {'evidenceKind':'known-installed-artifact-lineage', 'reference':reference, 'artifact':artifact,
            'remoteSignatureReadback':False, 'build':row['bundleVersion'],
            'deviceIdentifier':metadata['result'].get('deviceIdentifier'), 'metadataSHA256':digest_value(row),
            'securityEntitlements':{key:value for key,value in entitlements.items() if key != 'get-task-allow'},
            'ownerBootstrapSHA256':record.get('bootstrapSHA256')}

def log_nodes(value):
    if isinstance(value,dict):
        yield value
        for child in value.values():
            yield from log_nodes(child)
    elif isinstance(value,list):
        for child in value:
            yield from log_nodes(child)

def xcode_install_identity(action, session, artifact, bundle):
    require(action.get('result') == 'succeeded', 'xcode_action_failed')
    groups = [n for n in log_nodes(action) if any(c.get('title') == 'Installing built products'
              for c in n.get('subsections',[]))]
    require(len(groups) == 1, 'xcode_install_group_ambiguous')
    installs = [c for c in groups[0]['subsections'] if c.get('title') == 'Installing built products']
    require(len(installs) == 1 and installs[0].get('result') == 'succeeded' and
            installs[0].get('commandInvocationDetails',{}).get('exitCode') == 0 and
            any(m.get('title') == 'Successfully installed' for m in installs[0].get('messages',[])),
            'xcode_install_not_succeeded')
    launches = [c for c in groups[0]['subsections'] if c.get('title') == 'Launching CanvasBridgeUITests']
    require(len(launches) == 1 and launches[0].get('result') == 'succeeded', 'xcode_runner_launch_missing')
    titles = [n['title'] for n in log_nodes(launches[0]) if isinstance(n.get('title'),str)]
    require(titles.count('Launching ' + bundle) == 1, 'xcode_runner_launch_identity_mismatch')
    records = [t for t in titles if t.startswith('AppInstallationResult(')]
    require(len(records) == 1, 'xcode_install_record_ambiguous')
    match = re.fullmatch(r'AppInstallationResult\(applicationBundleId: "([^"]+)", installationURL: (file://[^,]+), '
        r'databaseUUID: ([A-Fa-f0-9-]{36}), databaseSequenceNumber: (\d+), _persistentIdentifier: \d+ bytes\)',records[0])
    require(match is not None and match[1] == bundle, 'xcode_install_identity_mismatch')
    url = match[2]
    endpoint = urllib.parse.urlsplit(url)
    require(endpoint.scheme == 'file' and not endpoint.netloc and not endpoint.query and not endpoint.fragment and
            re.fullmatch(r'/private/var/containers/Bundle/Application/[A-Fa-f0-9-]{36}/CanvasBridgeUITests-Runner.app/',endpoint.path) and
            titles.count('RemotePath: ' + endpoint.path.rstrip('/')) == 1, 'xcode_remote_path_mismatch')
    runnables = [n['testDetails'] for n in log_nodes(action) if isinstance(n.get('testDetails'),dict) and 'runnablePath' in n['testDetails']]
    require(len(runnables) == 1 and Path(runnables[0].get('runnablePath','')).is_dir() and
            Path(runnables[0]['runnablePath']).samefile(artifact), 'xcode_local_artifact_mismatch')
    # 한 실행의 host session -> install path -> runner load -> active configuration을 결속한다.
    event_pattern = re.compile(r'(?m)^\d{2}:\d{2}:\d{2}\.\d{3} (xcodebuild|CanvasBridgeUITests-Runner)\[(\d+):\d+\] (.*)$')
    matches = list(event_pattern.finditer(session))
    events = [{'process':m[1],'pid':m[2],'message':m[3],
        'body':session[m.end():matches[i+1].start() if i+1 < len(matches) else len(session)]}
        for i,m in enumerate(matches)]
    begins = [(i,e,re.match(r'Beginning test session CanvasBridgeUITests-([A-Fa-f0-9-]{36}) at ',e['message']))
              for i,e in enumerate(events) if e['process'] == 'xcodebuild' and e['message'].startswith('Beginning test session ')]
    active = [(i,e) for i,e in enumerate(events) if e['process'] == 'CanvasBridgeUITests-Runner' and
              e['message'].startswith('Running tests with active test configuration: <XCTestConfiguration: ')]
    remote = [(i,e,re.search(r"RemotePath '([^']+)' for bundleIdentifier: " + re.escape(bundle) + r'$',e['message']))
              for i,e in enumerate(events) if e['process'] == 'xcodebuild' and "RemotePath '" in e['message'] and
              e['message'].endswith('for bundleIdentifier: ' + bundle)]
    loads = [(i,e) for i,e in enumerate(events) if e['process'] == 'CanvasBridgeUITests-Runner' and
             e['message'].startswith('Loading test bundle at: ')]
    reason = 'xcode_session_context_mismatch'
    require(len(begins) == len(active) == len(remote) == len(loads) == 1 and begins[0][2] and remote[0][2],reason)
    start,host,begin = begins[0]; config_index,runner = active[0]; remote_index,installer,path = remote[0]; load_index,loader = loads[0]
    require(start < remote_index < load_index < config_index and host['pid'] == installer['pid'] and
            runner['pid'] == loader['pid'],reason)
    body = runner['body']
    session_ids = re.findall(r'(?m)^[ \t]*sessionIdentifier:([A-Fa-f0-9-]{36})[ \t]*$',body)
    require(len(session_ids) == 1 and session_ids[0].lower() == begin[1].lower(),reason)
    test_url = url + 'PlugIns/CanvasBridgeUITests.xctest/'
    config_urls = re.findall(r'(?m)^[ \t]*testBundleURL:([^\r\n]+)$',body)
    all_urls = re.findall(r'(?m)^[ \t]*testBundleURL:([^\r\n]+)$',session)
    dependencies = re.findall(r'(?ms)^[ \t]*testApplicationDependencies:[ \t]*\n\{(.*?)^\}',body)
    mapping_pattern = r'(?m)^[ \t]*"' + re.escape(bundle) + r'"[ \t]*=[ \t]*"(/[^"\r\n]+)";[ \t]*$'
    mappings = re.findall(mapping_pattern,dependencies[0]) if len(dependencies) == 1 else []
    all_mappings = re.findall(mapping_pattern,session)
    require(path[1] == endpoint.path.rstrip('/') and loader['message'] == 'Loading test bundle at: ' + test_url and
            config_urls == all_urls == [test_url] and len(mappings) == len(all_mappings) == 1 and
            mappings == all_mappings and Path(mappings[0]).is_dir() and Path(mappings[0]).samefile(artifact),
            'xcode_session_bundle_correlation_missing')
    return url

def verify_xcode_runner_lineage(config, work, reference, bundle):
    require(reference.get('schema') == 'ccr.known-installed-artifact/v1' and bundle == RUNNER_BUNDLE,
            'xcode_runner_lineage_only')
    artifact = Path(reference['artifact']).resolve()
    require(digest_value(artifact_files(artifact)) == reference['artifactManifestSHA256'], 'known_installed_artifact_changed')
    evidence = reference['xcode']
    result = Path(evidence['xcresultPath']).resolve()
    require(digest_value(artifact_files(result)) == evidence['xcresultManifestSHA256'], 'xcode_result_source_changed')
    invocation = Path(evidence['invocationLogPath']).read_bytes()
    require(sha(invocation) == evidence['invocationLogSHA256'], 'xcode_invocation_source_changed')
    lines = invocation.decode().splitlines()
    calls = [shlex.split(line.strip()) for line in lines if line.strip().startswith('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ')]
    require(len(calls) == 1 and digest_value(calls[0]) == evidence['invocationSHA256'], 'xcode_invocation_hash_mismatch')
    args = calls[0]
    require(args[1:2] == ['test-without-building'], 'xcode_invocation_action_mismatch')
    def option(name):
        require(args.count(name) == 1 and args.index(name)+1 < len(args), 'xcode_invocation_option_invalid')
        return args[args.index(name)+1]
    method = evidence['method']
    require(isinstance(method,str) and re.fullmatch('test[A-Za-z0-9_]+',method) and
            [a for a in args if a.startswith('-only-testing:')] == ['-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/' + method] and
            option('-destination') == 'id=' + config['deviceUDID'] and
            Path(option('-resultBundlePath')).samefile(result), 'xcode_invocation_target_mismatch')
    run = Path(option('-xctestrun'))
    require(run.is_file(), 'xcode_invocation_run_missing')
    action = json.loads(command(['xcrun','xcresulttool','get','log','--path',result,'--type','action','--compact']))
    require(digest_value(action) == evidence['actionSHA256'], 'xcode_action_source_changed')
    with tempfile.TemporaryDirectory(prefix='runner-diagnostics-',dir=work) as temporary:
        command(['xcrun','xcresulttool','export','diagnostics','--path',result,'--output-path',temporary])
        sessions = list(Path(temporary).rglob('Session-CanvasBridgeUITests-*.log'))
        require(len(sessions) == 1 and sha(sessions[0].read_bytes()) == evidence['sessionSHA256'], 'xcode_session_source_changed')
        url = xcode_install_identity(action,sessions[0].read_text(),artifact,bundle)
    summary = json.loads(command(['xcrun','xcresulttool','get','test-results','summary','--path',result,'--compact']))
    require(summary.get('result') == 'Passed' and
            all(type(summary.get(k)) is int for k in ['totalTestCount','passedTests','failedTests','skippedTests','expectedFailures']) and
            summary.get('totalTestCount') == summary.get('passedTests') == 1 and
            all(summary.get(k) == 0 for k in ['failedTests','skippedTests','expectedFailures']), 'xcode_single_pass_required')
    details = actual_xcresult(result,method)
    require(details['testRuns'][0].get('nodeIdentifier') == config['deviceUDID'], 'xcode_result_device_mismatch')
    metadata = pinned_json(reference,'metadataPath','metadataSHA256')
    metadata_args = metadata.get('info',{}).get('arguments',[])
    require(metadata.get('info',{}).get('outcome') == 'success' and
            metadata.get('info',{}).get('commandType') == 'devicectl.device.info.apps' and
            isinstance(metadata_args,list) and metadata_args.count('--device') == 1 and
            metadata_args.index('--device')+1 < len(metadata_args) and
            metadata_args[metadata_args.index('--device')+1] == config['deviceUDID'], 'xcode_metadata_device_mismatch')
    rows = [r for r in metadata.get('result',{}).get('apps',[]) if r.get('bundleIdentifier') == bundle]
    row = installed_app({'installedUserApp':{'apps':rows}},bundle)
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == bundle and info.get('CFBundleVersion') == row['bundleVersion'] and
            row.get('url') == url and isinstance(metadata['result'].get('deviceIdentifier'),str), 'xcode_metadata_mismatch')
    entitlements = signed_entitlements(artifact,work,'xcode-known-runner',bundle)
    binary = artifact / 'PlugIns/CanvasBridgeUITests.xctest/CanvasBridgeUITests'
    require(sha(binary.read_bytes()) == evidence['compiledTestsSHA256'], 'xcode_compiled_tests_changed')
    methods = runner_methods(binary)
    require(len(methods) == 21 and set(RUNNER_CORE_METHODS) <= methods and method in methods and
            'testReviewSelectedGrade' not in methods, 'xcode_installed_runner_capability_mismatch')
    require(digest_value(artifact_files(result)) == evidence['xcresultManifestSHA256'] and
            digest_value(artifact_files(artifact)) == reference['artifactManifestSHA256'] and
            sha(Path(evidence['invocationLogPath']).read_bytes()) == evidence['invocationLogSHA256'], 'xcode_inputs_changed')
    proof = {'artifactManifestSHA256':reference['artifactManifestSHA256'], **evidence,
             'sourceBindingSHA256':digest_value(reference), 'metadataSourceSHA256':reference['metadataSHA256'],
             'metadataRowSHA256':digest_value(row),'deviceIdentifier':metadata['result']['deviceIdentifier'],
             'installationURL':url,
             'methods':sorted(methods),'remoteSignatureReadback':False,
             'wrapperBuild':{k:info.get(k) for k in ['DTXcode','DTXcodeBuild','DTSDKName','DTSDKBuild']},
             'testBundleBuild':{k:plistlib.loads((binary.parent / 'Info.plist').read_bytes()).get(k) for k in ['DTXcode','DTXcodeBuild','DTSDKName','DTSDKBuild']},
             'tools':{'xcodebuild':command(['xcodebuild','-version']).strip(),
                      'xcresulttool':command(['xcrun','xcresulttool','version']).strip()}}
    write(work / 'xcode-runner-lineage.json',proof)
    return {'evidenceKind':'known-installed-artifact-lineage-from-xcode','reference':reference,'artifact':artifact,
            'remoteSignatureReadback':False,'build':row['bundleVersion'],
            'deviceIdentifier':metadata['result']['deviceIdentifier'],'metadataSHA256':digest_value(row),
            'securityEntitlements':{k:v for k,v in entitlements.items() if k != 'get-task-allow'},
            'provenance':proof}


def verify_prepared_artifact(config, work, source):
    require(not Path(config['preparedArtifact']).is_symlink(), 'prepared_artifact_symlink')
    app = Path(config['preparedArtifact']).resolve()
    receipt = pinned_json(config, 'preparedArtifactReceipt', 'preparedArtifactReceiptSHA256')
    require(receipt.get('schema') == 'ccr.signed-ipad-artifact/v1' and
            all(isinstance(source.get(key), str) and re.fullmatch('[0-9a-f]{40}', source[key]) and receipt.get(key) == source[key]
                for key in ['commit', 'tree']), 'prepared_artifact_source_mismatch')
    files = artifact_files(app)
    require(files == receipt.get('files') and digest_value(files) == receipt.get('manifestSHA256'),
            'prepared_artifact_manifest_mismatch')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == USER_BUNDLE and receipt.get('bundleIdentifier') == USER_BUNDLE and
            receipt.get('team') == NORMAL_TEAM and config['developmentTeam'] == NORMAL_TEAM,
            'prepared_normal_bundle_or_team_mismatch')
    require(all(info.get('CCRSource' + key.title()) == source[key] for key in ['commit', 'tree']) and
            info.get('CCRSourceIdentityVerified') is True, 'prepared_info_source_mismatch')
    settings = receipt.get('buildSettings', {})
    conditions = settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', [])
    require(receipt.get('configuration') == 'Debug' and settings.get('CONFIGURATION') == 'Debug' and
            isinstance(conditions, list) and 'DEBUG' in conditions and
            settings.get('PRODUCT_BUNDLE_IDENTIFIER') == USER_BUNDLE and
            settings.get('DEVELOPMENT_TEAM') == NORMAL_TEAM, 'prepared_debug_build_proof_required')
    build = info.get('CFBundleVersion')
    version_tuple(build)
    require(build == receipt.get('build') == settings.get('CURRENT_PROJECT_VERSION'), 'prepared_build_mismatch')
    executable = info.get('CFBundleExecutable')
    require(isinstance(executable, str) and re.fullmatch('[A-Za-z0-9_.-]+', executable) and
            executable in files, 'prepared_executable_missing')
    profile = owner_bootstrap_identity(config)
    require(files.get('CCR-OwnerMacBootstrap.json') == profile['sha256'] == receipt.get('ownerBootstrapSHA256') ==
            APPROVED_OWNER_PROFILE_SHA256,
            'prepared_actual_owner_profile_mismatch')
    entitlements = signed_entitlements(app, work, 'prepared')
    require(entitlements.get('get-task-allow') is True and
            entitlements.get('com.apple.developer.team-identifier') == NORMAL_TEAM and
            entitlements.get('application-identifier') == NORMAL_TEAM + '.' + USER_BUNDLE and
            sha(plistlib.dumps(entitlements, sort_keys=True)) == receipt.get('entitlementsSHA256'),
            'prepared_entitlements_mismatch')
    require('embedded.mobileprovision' in files, 'prepared_mobileprovision_missing')
    provision = plistlib.loads(command(['security', 'cms', '-D', '-i', app / 'embedded.mobileprovision']).encode())
    expiry = provision.get('ExpirationDate')
    if isinstance(expiry, dt.datetime) and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    allowed = provision.get('Entitlements', {})
    require(provision.get('TeamIdentifier') == [NORMAL_TEAM] and isinstance(expiry, dt.datetime) and
            expiry > dt.datetime.now(dt.timezone.utc) and config['deviceUDID'] in provision.get('ProvisionedDevices', []) and
            allowed.get('get-task-allow') is True and
            fnmatch.fnmatchcase(entitlements['application-identifier'], allowed.get('application-identifier', '')) and
            all(any(fnmatch.fnmatchcase(group, pattern) for pattern in allowed.get('keychain-access-groups', []))
                for group in entitlements.get('keychain-access-groups', [])), 'prepared_provisioning_not_authorized')
    return app, receipt, files, entitlements, profile

def deploy_prepared(config, work, source):
    required = ['preparedArtifact', 'preparedArtifactReceipt', 'preparedArtifactReceiptSHA256',
                'installedIdentityReceipt', 'installedIdentityReceiptSHA256', 'preparedContext',
                'preparedContextSHA256', 'ownerBootstrapProfile', 'ownerBootstrapSHA256',
                'developmentTeam', 'leaseFile', 'deviceUDID']
    require(all(key in config for key in required), 'prepared_inputs_missing')
    lease(config)
    work.chmod(0o700)
    require(not (work / 'prepared-install-attempt.json').exists(), 'prepared_install_already_attempted_readback_required')
    app, receipt, files, entitlements, profile = verify_prepared_artifact(config, work, source)
    prior = known_installed_lineage(config, work)
    security = {key: value for key, value in entitlements.items() if key != 'get-task-allow'}
    require(prior.get('securityEntitlements') == security and
            prior.get('ownerBootstrapSHA256') == profile['sha256'], 'existing_security_entitlements_changed')
    context = pinned_json(config, 'preparedContext', 'preparedContextSHA256')
    test_id = context.get('id', '')
    require(context.get('schema') == 'ccr.ipad-test-context/v1' and isinstance(test_id, str) and str(uuid.UUID(test_id)) == test_id and
            all(context.get(key) == source[key] for key in ['commit', 'tree']), 'prepared_context_source_mismatch')
    endpoint = urllib.parse.urlsplit(context.get('relayAddress', ''))
    require(endpoint.scheme == 'http' and not endpoint.username and not endpoint.password and
            not endpoint.path and not endpoint.query and not endpoint.fragment and endpoint.port == 8793 and
            ipaddress.ip_address(endpoint.hostname).version == 4 and ipaddress.ip_address(endpoint.hostname).is_private and
            isinstance(context.get('token'), str) and len(context['token']) >= 24, 'prepared_context_relay_invalid')
    baseline = snapshots(config, work, 'prepared-before')
    installed = installed_normal(baseline)
    require(prior.get('build') == installed['bundleVersion'] and
            prior.get('metadataSHA256') == digest_value(installed) and
            prior.get('deviceIdentifier') == baseline['installedUserApp'].get('deviceIdentifier'),
            'installed_reference_not_current')
    require(version_tuple(receipt['build']) > version_tuple(installed['bundleVersion']), 'prepared_build_not_newer')
    staged = work / 'PreparedArtifact/Sill.app'
    require(not staged.exists() and not staged.parent.is_symlink(), 'prepared_staging_already_exists')
    staged.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copytree(app, staged)
    require(artifact_files(staged) == files, 'prepared_staging_mismatch')
    rechecked = snapshots(config, work, 'prepared-preinstall')
    require(same_user_data(baseline, rechecked) and installed_normal(rechecked) == installed,
            'normal_state_changed_before_install')
    def unchanged_inputs():
        lease(config)
        require(identity(config) == source, 'prepared_source_changed_before_effect')
        for path_key, hash_key in [('preparedArtifactReceipt', 'preparedArtifactReceiptSHA256'),
                                   ('installedIdentityReceipt', 'installedIdentityReceiptSHA256'),
                                   ('preparedContext', 'preparedContextSHA256')]:
            pinned_json(config, path_key, hash_key)
        lineage_inputs(prior['reference'])
        require(artifact_files(app) == files and artifact_files(staged) == files and
                sha(Path(profile['path']).read_bytes()) == profile['sha256'], 'prepared_input_changed_before_effect')
    unchanged_inputs()
    attempt = {'schema': 'ccr.prepared-install-attempt/v1', **source, 'testId': test_id,
               'artifactManifestSHA256': receipt['manifestSHA256'],
               'artifactReceiptSHA256': config['preparedArtifactReceiptSHA256'],
               'installedIdentityReceiptSHA256': config['installedIdentityReceiptSHA256'],
               'contextSHA256': config['preparedContextSHA256'], 'baselineSHA256': digest_value(baseline),
               'securityEntitlementsSHA256': digest_value(security),
               'status': 'install-requested', 'normalReturnRequired': True}
    install_attempt(work, attempt)
    try:
        command(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['deviceUDID'],
                 staged, '--json-output', work / 'prepared-install.json'], work / 'prepared-install.log', 120)
        after = snapshots(config, work, 'prepared-after-install')
        require(installed_normal(after)['bundleVersion'] == receipt['build'] and same_user_data(baseline, after),
                'prepared_install_data_or_metadata_mismatch')
        unchanged_inputs()
        root = 'Library/Application Support/CCRIntegrationTests/' + test_id
        context_path = work / 'prepared-context.json'
        write(context_path, context)
        state = work / 'prepared-state'; state.mkdir(mode=0o700)
        write(state / 'CanvasScene.json', fixture(test_id))
        copy_file(config, work, state, root + '/state', 'to', bundle=USER_BUNDLE)
        copy_file(config, work, context_path, root + '/context.json', 'to', bundle=USER_BUNDLE)
        unchanged_inputs()
        device(config, ['process', 'launch', USER_BUNDLE, '--json-output', str(work / 'prepared-launch.json'),
                        '--', '--ccr-test-runtime', test_id], work / 'prepared-launch.log')
        time.sleep(2)
        runtime, evidence = runtime_readback(config, work, test_id, bundle=USER_BUNDLE)
        executable = plistlib.loads((staged / 'Info.plist').read_bytes())['CFBundleExecutable']
        code_images = artifact_code_images(files,executable)
        validate_runtime_code_images(runtime,code_images,installed_normal(after)['url'])
        require(all(runtime.get(key) == source[key] for key in ['commit', 'tree']) and
                runtime.get('bundleID') == USER_BUNDLE and str(runtime.get('build')) == receipt['build'] and
                runtime.get('executableSHA256') == files[plistlib.loads((staged / 'Info.plist').read_bytes())['CFBundleExecutable']] and
                runtime.get('relayAddress') == context['relayAddress'] and
                str(runtime.get('storageRoot', '')).endswith('/' + root + '/state'), 'prepared_runtime_source_mismatch')
        launched = read(work / 'prepared-launch.json').get('result', {}).get('processIdentifier')
        require(type(launched) is int and launched > 0 and runtime.get('processID') == launched,
                'prepared_runtime_launch_pid_mismatch')
        processes_path = work / 'prepared-processes.json'
        device(config, ['info', 'processes', '--json-output', str(processes_path)], work / 'prepared-processes.log')
        matches = [row for row in read(processes_path).get('result', {}).get('runningProcesses', [])
                   if row.get('processIdentifier') == launched]
        executable = plistlib.loads((staged / 'Info.plist').read_bytes())['CFBundleExecutable']
        expected = urllib.parse.urljoin(installed_normal(after)['url'].rstrip('/') + '/', executable)
        require(len(matches) == 1 and matches[0].get('executable') == expected, 'prepared_running_executable_mismatch')
        final = snapshots(config, work, 'prepared-after-isolated')
        require(installed_normal(final) == installed_normal(after) and same_user_data(baseline, final),
                'normal_data_or_metadata_changed_by_isolated_runtime')
        unchanged_inputs()
        result = {'status': 'applied', **source, 'bundleIdentifier': USER_BUNDLE, 'configuration': 'Debug',
                  'sourceReadbackVerified': True, 'testId': test_id,
                  'runtimeId': USER_BUNDLE + ':' + test_id + ':' + digest_value(code_images),
                  'codeImages':code_images,'codeImagesSHA256':digest_value(code_images),
                  'executableSHA256': runtime['executableSHA256'], 'sourceReadback': str(evidence),
                  'app': str(staged), 'artifactManifestSHA256': receipt['manifestSHA256'],
                  'normalReturnRequired': True, 'functionalAcceptance': False}
        result.update(protectionBaseline='prepared-before.json', protectionBaselineSHA256=digest_value(baseline),
                      signingEvidenceKind=prior['evidenceKind'],
                      installedMetadataSHA256=digest_value(installed_normal(final)),
                      deviceIdentifier=final['installedUserApp'].get('deviceIdentifier'))
        write(work / 'deployment.json', result)
        install_attempt(work, dict(attempt, status='isolated-runtime-verified'))
        return result
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        install_attempt(work, dict(attempt, status='held-after-install-attempt'))
        raise

def stop_owned(config, work):
    if config.get('_runtimeBundle') == USER_BUNDLE:
        deployed = prepared_runtime(config, work, allow_stopped=True)
        runtime = deployed['_runtime']
        if deployed['_running']:
            device(config, ['process', 'terminate', '--pid', str(runtime['processID'])], work / 'stop.log')
            path = work / 'stopped-processes.json'
            device(config, ['info', 'processes', '--json-output', str(path)], work / 'stopped-processes.log')
            require(not any(row.get('processIdentifier') == runtime['processID'] for row in
                    read(path).get('result', {}).get('runningProcesses', [])), 'prepared_process_stop_unconfirmed')
        write(work / 'owned-stop.json', {'testId':deployed['testId'], 'runtime':runtime,
            'artifactManifestSHA256':deployed['artifactManifestSHA256'], 'confirmedAbsentPID':runtime['processID']})
        return
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
    single_app_installation_gate()
    lease(config)
    previous = snapshots(config, work, 'user-before-current')
    if (work / 'user-before.json').exists():
        require(same_user_data(read(work / 'user-before.json'), previous), 'user_data_changed_since_previous_deploy')
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
             '-configuration', 'Debug', '-destination', 'generic/platform=iOS', '-derivedDataPath', derived,
             'DEVELOPMENT_TEAM=' + config['developmentTeam'], 'CURRENT_PROJECT_VERSION=' + version,
             'PRODUCT_BUNDLE_IDENTIFIER=' + BUNDLE, 'INFOPLIST_FILE=' + str(metadata_path),
             'CCR_SOURCE_EXTERNAL_INFO_FILE=' + str(metadata_path),
             'CCR_SOURCE_GIT_COMMON_DIR=' + command(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=config['repo']).strip(),
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
    require(same_user_data(snapshots(config, work, 'user-after-deploy'), previous), 'original_data_changed')
    result = {'status': 'applied', **source, 'runtimeId': BUNDLE + ':' + test_id + ':' + executable,
              'testId': test_id, 'executableSHA256': executable, 'sourceReadback': str(evidence), 'app': str(app)}
    write(work / 'deployment.json', result)
    stop_owned(config, work)
    return result

def run_live_harness(args, log, on_ready, timeout=180, ready_marker='CCR_ROTATION_LIVE_READY'):
    with log.open('w') as output:
        process = subprocess.Popen(args, env=ENV, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        applied = False
        try:
            while process.poll() is None:
                require(time.monotonic() < deadline, 'live_rotation_ui_timeout')
                if not applied and ready_marker in log.read_text():
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

def actual_xcresult(result, method):
    require(Path(result).is_dir(), 'xcresult_missing')
    identity = 'CanvasBridgeUITests/' + method + '()'
    url = 'test://com.apple.xcode/CanvasBridge/CanvasBridgeUITests/' + identity[:-2]
    details = json.loads(command(['xcrun','xcresulttool','get','test-results','test-details',
                                  '--path',str(result),'--test-id',identity]))
    require(isinstance(details,dict) and details.get('testIdentifier') == identity and
            details.get('testIdentifierURL') == url and details.get('testResult') == 'Passed',
            'xcresult_method_not_passed')
    runs = details.get('testRuns')
    require(isinstance(runs,list) and len(runs) == 1 and isinstance(runs[0],dict) and
            runs[0].get('nodeType') == 'Device' and runs[0].get('result') == 'Passed',
            'xcresult_execution_count_or_status')
    configurations = runs[0].get('children')
    require(isinstance(configurations,list) and len(configurations) == 1 and
            isinstance(configurations[0],dict) and
            configurations[0].get('nodeType') == 'Test Plan Configuration' and
            configurations[0].get('nodeIdentifierURL') == url and
            configurations[0].get('result') == 'Passed' and not configurations[0].get('children'),
            'xcresult_execution_count_or_status')
    return details

def harness(config, work, method, variables=None, on_ready=None, ready_marker='CCR_ROTATION_LIVE_READY'):
    deployed = prepared_runtime(config, work, allow_stopped=True)
    lease(config)
    run_path = Path(config['existingXctestrun']).resolve()
    runner = verified_runner(config, work, method)
    run_bytes = run_path.read_bytes()
    require(sha(run_bytes) == config['existingXctestrunSHA256'], 'existing_xctestrun_changed')
    require(deployed.get('bundleIdentifier') == USER_BUNDLE and deployed.get('configuration') == 'Debug' and
            deployed.get('sourceReadbackVerified') is True, 'normal_debug_runtime_receipt_required')
    run = destination_artifacts_run(plistlib.loads(run_bytes),runner,deployed['testId'],variables)
    prepared = work / 'ExistingRunner.xctestrun'
    prepared.write_bytes(plistlib.dumps(run,fmt=plistlib.FMT_BINARY))
    result = work / (method + '-' + str(time.time_ns()) + '.xcresult')
    args = ['xcodebuild', 'test-without-building', '-xctestrun', str(prepared), '-destination', 'id=' + config['deviceUDID'],
            '-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/' + method, '-resultBundlePath', str(result),
            '-parallel-testing-enabled', 'NO']
    log = work / (method + '.log')
    if on_ready is None:
        command(args, log, 180)
    else:
        run_live_harness(args, log, on_ready, ready_marker=ready_marker)
    actual_xcresult(result, method)
    return result

def prepared_runtime(config, work, source=None, allow_stopped=False):
    require((work / 'deployment.json').is_file() and 'preparedArtifactReceipt' in config, 'prepared_deployment_required')
    lease(config)
    deployed = read(work / 'deployment.json')
    expected = source or {key:deployed.get(key) for key in ['commit','tree']}
    require(deployed.get('bundleIdentifier') == USER_BUNDLE and deployed.get('configuration') == 'Debug' and
            deployed.get('sourceReadbackVerified') is True and
            all(deployed.get(key) == expected[key] for key in expected) and identity(config) == expected,
            'prepared_deployment_source_mismatch')
    _, receipt, files, _, _ = verify_prepared_artifact(config, work, expected)
    attempt = read(work / 'prepared-install-attempt.json')
    require(attempt.get('status') == 'isolated-runtime-verified' and
            attempt.get('artifactManifestSHA256') == receipt['manifestSHA256'] and
            attempt.get('contextSHA256') == config['preparedContextSHA256'] and
            attempt.get('artifactReceiptSHA256') == config['preparedArtifactReceiptSHA256'] and
            attempt.get('testId') == deployed['testId'] and all(attempt.get(k) == expected[k] for k in expected),
            'prepared_attempt_not_verified')
    artifact = Path(deployed['app']).resolve()
    require(artifact == (work / 'PreparedArtifact/Sill.app').resolve() and artifact_files(artifact) == files and
            deployed.get('artifactManifestSHA256') == receipt['manifestSHA256'], 'prepared_runtime_artifact_changed')
    context = pinned_json(config, 'preparedContext', 'preparedContextSHA256')
    require(context.get('id') == deployed['testId'] and all(context.get(key) == expected[key] for key in expected),
            'prepared_runtime_context_changed')
    runtime, _ = runtime_readback(config, work, deployed['testId'], bundle=USER_BUNDLE, optional=allow_stopped)
    if runtime is None:
        stopped = read(work / 'owned-stop.json')
        runtime = stopped['runtime']
        require(stopped.get('testId') == deployed['testId'] and
                stopped.get('artifactManifestSHA256') == receipt['manifestSHA256'] and
                stopped.get('confirmedAbsentPID') == runtime.get('processID'), 'prepared_stop_reference_mismatch')
    require(runtime.get('id') == deployed['testId'] and runtime.get('bundleID') == USER_BUNDLE and
            all(runtime.get(key) == expected[key] for key in expected) and runtime.get('build') == receipt['build'] and
            runtime.get('executableSHA256') == deployed['executableSHA256'] and
            runtime.get('relayAddress') == context.get('relayAddress') and
            type(runtime.get('processID')) is int and runtime['processID'] > 0, 'prepared_runtime_mismatch')
    inventory = work / 'prepared-current-apps.json'
    device(config, ['info','apps','--filter','bundleIdentifier == "' + USER_BUNDLE + '"','--json-output',str(inventory)],
           work / 'prepared-current-apps.log')
    row = installed_normal({'installedUserApp':read(inventory).get('result')})
    require(row['bundleVersion'] == receipt['build'] and digest_value(row) == deployed.get('installedMetadataSHA256') and
            read(inventory).get('result',{}).get('deviceIdentifier') == deployed.get('deviceIdentifier'),
            'prepared_installed_metadata_changed')
    process_file = work / 'prepared-current-processes.json'
    device(config, ['info','processes','--json-output',str(process_file)], work / 'prepared-current-processes.log')
    processes = read(process_file).get('result', {}).get('runningProcesses', [])
    executable = plistlib.loads((artifact / 'Info.plist').read_bytes())['CFBundleExecutable']
    require(deployed['executableSHA256'] == files[executable] and
            str(runtime.get('storageRoot', '')).endswith('/Library/Application Support/CCRIntegrationTests/' + deployed['testId'] + '/state'),
            'prepared_runtime_storage_or_binary_mismatch')
    code_images = artifact_code_images(files,executable)
    require(deployed.get('codeImages') == code_images and deployed.get('codeImagesSHA256') == digest_value(code_images),
            'prepared_code_images_unsupported_or_changed')
    validate_runtime_code_images(runtime,code_images,row['url'])
    expected_path = urllib.parse.urljoin(row['url'].rstrip('/') + '/', executable)
    matching = [p for p in processes if p.get('processIdentifier') == runtime['processID']]
    require((len(matching) == 1 and matching[0].get('executable') == expected_path) or
            (allow_stopped and not matching and not any(p.get('executable') == expected_path for p in processes)),
            'prepared_runtime_process_mismatch')
    return dict(deployed, _runtime=runtime, _running=bool(matching))

def test_context_path(config, work):
    return Path(config['preparedContext']) if config.get('_runtimeBundle') == USER_BUNDLE else work / 'context.json'

def verified_runner(config, work, method):
    receipt = pinned_json(config, 'existingRunnerReceipt', 'existingRunnerReceiptSHA256')
    require(receipt.get('schema') == 'ccr.known-installed-runner/v1', 'known_installed_runner_lineage_required')
    bundle = 'com.ambrion.rea.appaudit.UITests.xctrunner'
    lineage = verify_known_lineage(config, work, receipt['lineage'], bundle)
    binary = lineage['artifact'] / 'PlugIns/CanvasBridgeUITests.xctest/CanvasBridgeUITests'
    requested = {method} if isinstance(method,str) else set(method)
    missing = requested - runner_methods(binary)
    require(requested and not missing, 'existing_runner_method_unavailable:' + ','.join(sorted(missing)))
    path = work / 'existing-runner-current-apps.json'
    device(config, ['info','apps','--bundle-id',bundle,'--json-output',str(path)], work / 'existing-runner-current-apps.log')
    current = read(path).get('result', {})
    row = installed_app({'installedUserApp':current}, bundle)
    require(digest_value(row) == lineage['metadataSHA256'] and current.get('deviceIdentifier') == lineage['deviceIdentifier'],
            'existing_runner_metadata_changed')
    return {'schema':'ccr.existing-xctest-runner/v1','installed':True,'team':NORMAL_TEAM,
            'bundleIdentifier':bundle,'testBundleRelativePath':'__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest'}

def runner_methods(binary):
    symbols = [s for s in command(['nm','-j',binary]).splitlines() if 'CanvasBridgeUITests' in s and 'test' in s]
    require(symbols and sum(map(len,symbols)) < 64000, 'existing_runner_symbols_unavailable')
    demangled = command(['xcrun','swift-demangle','--compact',*symbols])
    return set(re.findall(r'CanvasBridgeUITests\.CanvasBridgeUITests\.(test\w+)\(', demangled))

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
    start['nodes'][0]['frame']['y'] = 300
    second = '42478F2C-F81D-4AC9-B714-ECBD9DDAC411'
    start['nodes'].append(dict(start['nodes'][0], id=second, text='연결 대상',
                              frame={'x':1050,'y':700,'width':260,'height':120}))
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
    copy_file(config, work, test_context_path(config, work), 'Library/Application Support/CCRIntegrationTests/' + test_id + '/context.json', 'to')
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

def comment_fixture(test_id):
    scene = fixture(test_id)
    scene['nodes'][0]['frame']['y'] = 300
    scene['nodes'].append(dict(scene['nodes'][0], id='42478F2C-F81D-4AC9-B714-ECBD9DDAC411',
                               text='댓글 없는 카드', frame={'x':1050,'y':500,'width':260,'height':120}))
    scene['annotations'] = [{'id':'9A061215-B87D-4549-8548-56DDC78FC103','nodeId':NODE,
                             'text':'보존할 AI 주석 👩🏽‍💻','author':'AI'}]
    return scene

def verify_comment_scene(scene, baseline, text, comment_id=None):
    comments = [row for row in scene['annotations'] if row['author'] == '사용자']
    require(len(comments) == 1 and comments[0].get('nodeId') == NODE and comments[0]['text'] == text,
            'comment_text_or_target_mismatch')
    current = comments[0]
    try:
        parsed = uuid.UUID(current['id'])
    except (ValueError, KeyError, TypeError, AttributeError):
        raise Held('comment_id_invalid')
    require(parsed.int != 0 and (comment_id is None or current['id'] == comment_id), 'comment_id_changed')
    require(len({row['id'] for row in scene['annotations']}) == len(scene['annotations']), 'comment_id_collision')
    preserved = dict(scene, revision=baseline['revision'],
                     annotations=[row for row in scene['annotations'] if row is not current])
    require(scene['revision'] > baseline['revision'] and preserved == baseline,
            'comment_changed_original_or_ai_annotation')
    return current['id']

def accept_comments(config, work, server, test_id):
    code, prior = request(server, 'GET', '/vault/canvas?id=' + test_id)
    require(code == 200, 'comment_seed_lookup_failed')
    baseline = comment_fixture(test_id)
    baseline['revision'] = prior['revision'] + 1
    baseline = json.loads(encode_scene(server,baseline))
    code, _ = save_scene(server,baseline,pixel(),prior['noteSha256'])
    require(code == 200, 'comment_seed_failed')
    stop_owned(config,work)
    seed = work / 'comment-state'; seed.mkdir(exist_ok=True)
    write(seed / 'CanvasScene.json',baseline)
    root = 'Library/Application Support/CCRIntegrationTests/' + test_id
    copy_file(config,work,seed,root + '/state','to',replace=True)
    copy_file(config,work,test_context_path(config, work),root + '/context.json','to')
    results = []
    previous = ''
    previous_revision = baseline['revision']
    comment_id = None
    for text in ['첫 댓글 👩🏽‍💻 원문 보존','수정 댓글 · 같은 카드']:
        ui = harness(config,work,'testCommentSave',{'CCR_COMMENT_TEXT':text,'CCR_COMMENT_PREVIOUS':previous})
        code, saved = request(server,'GET','/vault/canvas?id=' + test_id)
        require(code == 200, 'comment_vault_readback_failed')
        scene = json.loads(base64.b64decode(saved['sceneJSONBase64']))
        comment_id = verify_comment_scene(scene,baseline,text,comment_id)
        require(scene['revision'] > previous_revision, 'comment_revision_not_increased')
        previous_revision = scene['revision']
        local = work / ('comment-device-' + str(len(results)) + '.json')
        copy_file(config,work,root + '/state/CanvasScene.json',local)
        require(read(local) == scene, 'comment_device_vault_mismatch')
        reopened = harness(config,work,'testCommentReopen',{'CCR_COMMENT_TEXT':text})
        results.append({'ui':str(ui),'reopen':str(reopened),'vault':saved,'deviceScene':str(local)})
        previous = text
    stale = harness(config,work,'testStaleCommentDraftRequiresExplicitDiscard',{'CCR_COMMENT_TEXT':previous})
    reopen = harness(config,work,'testCommentReopen',{'CCR_COMMENT_TEXT':previous})
    ruler = harness(config,work,'testRulerToggleAcrossDrawingAndSelection')
    code, final = request(server,'GET','/vault/canvas?id=' + test_id)
    require(code == 200 and final == saved, 'comment_discard_or_ruler_changed_vault')
    local = work / 'comment-final-device-scene.json'
    copy_file(config,work,root + '/state/CanvasScene.json',local)
    require(read(local) == scene, 'comment_discard_or_ruler_changed_device')
    proof = {'edits':results,'staleDraftDiscard':str(stale),'finalReopen':str(reopen),'rulerToggle':str(ruler),
             'commentID':comment_id,'baseline':baseline,'finalVault':final,'deviceScene':str(local),
             'input':'XCTest keyboard UI; Apple Pencil sensor input unverified',
             'rulerScope':'native menu toggle and drawing/selection mode; physical ruler geometry unverified',
             'nativeLifetimeProbe':'separate opt-in testNativeModeLifetimeProbe; not executed by this flow'}
    write(work / 'comment-functional-readback.json',proof)
    return proof

def review_fixture(test_id):
    # Same canonical header and four markers as VaultReviewCard; all other bytes are sentinels.
    metadata = {'cardID':'11111111-1111-4111-8111-111111111111',
                'eventID':'22222222-2222-4222-8222-222222222222',
                'ratedAt':1700000000, 'dueAt':1700086400}
    return {'path':'CCR-Review-' + test_id + '.md', 'metadata':metadata,
            'prefix':'---\r\ntitle: 복습 자체 검사\r\n---\r\n\r\n바깥 원문 👩🏽‍💻 e\u0301 한\r\n\r\n',
            'suffix':'바깥 끝 · 유지\r\n```text\r\n수정 금지\r\n```\r\n',
            'question':'한글 질문 👩🏽‍💻 e\u0301', 'answer':'원래 답 한 · 보존'}

def review_text(fixture, question, answer, metadata):
    return fixture['prefix'] + '\n'.join([
        '<!-- ccr-review-card:v1 ' + json.dumps(metadata,ensure_ascii=False,sort_keys=True,separators=(',',':')) + ' -->',
        '<!-- ccr-review-front -->',question,'<!-- ccr-review-back -->',answer,'<!-- /ccr-review-card -->','']) + fixture['suffix']

def review_note(server, vault, path, expected=None):
    code, note = request(server,'GET','/vault/note?' + urllib.parse.urlencode({'path':path}))
    require(code == 200 and note.get('path') == path and isinstance(note.get('text'),str), 'review_note_readback_failed')
    raw = note['text'].encode()
    require(note.get('sha256') == sha(raw) and (vault / path).read_bytes() == raw, 'review_note_hash_mismatch')
    require(expected is None or raw == expected.encode(), 'review_note_bytes_mismatch')
    return note

def review_journal(config, work, test_id, label, expected=None):
    destination = work / ('review-journal-' + label + '.json')
    copy_file(config,work,'Library/Application Support/CCRIntegrationTests/' + test_id +
              '/state/CanvasNoteEdit/recovery.json',destination)
    envelope = read(destination)
    require(isinstance(envelope,dict) and type(envelope.get('schemaVersion')) is int and
            envelope['schemaVersion'] == 1, 'review_journal_schema_mismatch')
    record = None
    raw = b''
    if 'payload' in envelope:
        require(isinstance(envelope['payload'],str) and envelope['payload'], 'review_journal_payload_invalid')
        raw = base64.b64decode(envelope['payload'],validate=True)
        record = json.loads(raw)
        require(isinstance(record,dict) and type(record.get('schemaVersion')) is int and
                record['schemaVersion'] == 1, 'review_journal_record_invalid')
    require(envelope.get('sha256') == sha(raw), 'review_journal_hash_mismatch')
    if expected is None:
        require(record is None, 'review_journal_not_cleared')
    else:
        require(record is not None and isinstance(record.get('sceneID'),str) and
                record.get('sceneID','').lower() == test_id.lower() and
                all(record.get(k) == v for k,v in expected.items()) and
                record.get('submittedText') is None and record.get('nodeID') is None and record.get('blockID') is None,
                'review_journal_draft_mismatch')
    return str(destination)

def review_writes(work, path):
    audit = work / 'review-note-writes.jsonl'
    require(audit.is_file(), 'review_wire_evidence_missing')
    rows = [json.loads(line) for line in audit.read_text().splitlines()]
    return [row for row in rows if row.get('path') == path]

def accept_review(config, work, server, vault, test_id):
    card = review_fixture(test_id)
    path = card['path']; endpoint = '/vault/note?' + urllib.parse.urlencode({'path':path})
    metadata = card['metadata']
    original = review_text(card,card['question'],card['answer'],metadata)
    other_path = 'CCR-Review-Other-' + test_id + '.md'
    other = dict(metadata,cardID='33333333-3333-4333-8333-333333333333')
    other_text = review_text(card,'다른 노트 질문','다른 노트 답',other)
    for name, text in [(path,original),(other_path,other_text)]:
        url = '/vault/note?' + urllib.parse.urlencode({'path':name})
        code, _ = request(server,'GET',url)
        require(code == 404, 'review_fixture_already_exists')
        code, _ = request(server,'PUT',url,{'baseSha256':None,'text':text})
        require(code == 200, 'review_fixture_seed_failed')
        review_note(server,vault,name,text)
    baseline = work / 'review-scene-before.json'
    state = 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/CanvasScene.json'
    copy_file(config,work,state,baseline)
    seed = review_note(server,vault,path,original)
    question = card['question'] + ' / UIKit question'
    answer = card['answer'] + ' / UIKit answer'
    draft = review_text(card,question,answer,metadata)
    variables = {'CCR_REVIEW_NOTE':path, 'CCR_REVIEW_INITIAL_QUESTION':card['question'],
                 'CCR_REVIEW_INITIAL_ANSWER':card['answer'], 'CCR_REVIEW_QUESTION':question,
                 'CCR_REVIEW_ANSWER':answer, 'CCR_REVIEW_DRAFT':draft}
    results = {}
    results['draft'] = str(harness(config,work,'testReviewEditDraftPreserved',variables))
    review_note(server,vault,path,original)
    pending = review_journal(config,work,test_id,'draft',
        {'relayAddress':server['address'],'base':seed,'draft':draft})
    results['save'] = str(harness(config,work,'testReviewSaveDraft',variables))
    edited = review_note(server,vault,path,draft)
    cleared = [review_journal(config,work,test_id,'saved')]
    results['reopen'] = str(harness(config,work,'testReviewReopen',variables))
    review_note(server,vault,path,draft)

    remote_question = question + ' / Mac 외부 수정'
    remote_answer = answer + ' / 양방향 👩🏽‍💻'
    remote_text = review_text(card,remote_question,remote_answer,metadata)
    def remote_update(base, text):
        code, _ = request(server,'PUT',endpoint,{'baseSha256':base,'text':text})
        require(code == 200, 'review_remote_update_failed')
        review_note(server,vault,path,text)
    remote_variables = dict(variables,CCR_REVIEW_REMOTE_QUESTION=remote_question,
                            CCR_REVIEW_REMOTE_ANSWER=remote_answer,CCR_REVIEW_REMOTE_TEXT=remote_text)
    results['live'] = str(harness(config,work,'testReviewLiveRemoteRevision',remote_variables,
        on_ready=lambda:remote_update(edited['sha256'],remote_text),ready_marker='CCR_REVIEW_LIVE_READY'))
    latest = review_note(server,vault,path,remote_text)
    variables.update(CCR_REVIEW_QUESTION=remote_question,CCR_REVIEW_ANSWER=remote_answer,CCR_REVIEW_DRAFT=remote_text)
    results['remoteReopen'] = str(harness(config,work,'testReviewReopen',variables))
    started = int(time.time())
    before_grade = review_writes(work,path)
    results['good'] = str(harness(config,work,'testReviewGood',variables))
    rated = review_note(server,vault,path)
    headers = re.findall(r'^<!-- ccr-review-card:v1 (.+) -->$',rated['text'],re.MULTILINE)
    require(len(headers) == 1, 'review_metadata_missing')
    grade = json.loads(headers[0])
    require(set(grade) == set(metadata) and grade['cardID'] == metadata['cardID'], 'review_card_identity_changed')
    event = grade['eventID']
    require(isinstance(event,str) and str(uuid.UUID(event)) == event and
            event not in [metadata['eventID'],metadata['cardID'],str(uuid.UUID(int=0))], 'review_event_identity_invalid')
    require(type(grade['ratedAt']) is int and type(grade['dueAt']) is int and
            started <= grade['ratedAt'] <= int(time.time()) and grade['dueAt']-grade['ratedAt'] == 86400,
            'review_good_interval_invalid')
    rated_text = review_text(card,remote_question,remote_answer,grade)
    review_note(server,vault,path,rated_text)
    grade_writes = review_writes(work,path)[len(before_grade):]
    require(grade_writes == [{'path':path,'status':200,'baseSha256':latest['sha256'],
                              'textSha256':rated['sha256']}], 'review_duplicate_or_failed_grade_request')
    cleared.append(review_journal(config,work,test_id,'rated'))
    variables['CCR_REVIEW_DRAFT'] = rated_text
    results['ratedReopen'] = str(harness(config,work,'testReviewReopen',variables))
    unchanged = review_note(server,vault,path,rated_text)
    require(unchanged['sha256'] == rated['sha256'] and unchanged['modifiedAt'] == rated['modifiedAt'],
            'review_duplicate_rating_effect')
    require(review_writes(work,path) == before_grade + grade_writes, 'review_reopen_repeated_grade_request')

    stale_question = remote_question + ' / stale 차단'
    stale_text = review_text(card,stale_question,remote_answer,grade)
    stale_variables = dict(variables,CCR_REVIEW_REMOTE_QUESTION=stale_question,
                           CCR_REVIEW_REMOTE_ANSWER=remote_answer,CCR_REVIEW_REMOTE_TEXT=stale_text)
    before_stale = review_writes(work,path)
    results['stale'] = str(harness(config,work,'testReviewStaleSessionRejected',stale_variables,
        on_ready=lambda:remote_update(rated['sha256'],stale_text),ready_marker='CCR_REVIEW_STALE_READY'))
    current = review_note(server,vault,path,stale_text)
    require(review_writes(work,path) == before_stale + [{'path':path,'status':200,
            'baseSha256':rated['sha256'],'textSha256':current['sha256']}], 'review_stale_ui_submitted_write')
    code, _ = request(server,'PUT',endpoint,{'baseSha256':latest['sha256'],'text':remote_text})
    require(code == 409, 'review_stale_cas_not_rejected')
    code, _ = request(server,'PUT',endpoint,{'baseSha256':current['sha256'],'text':'unauthorized'},authenticated=False)
    require(code == 401, 'review_unauthenticated_write_not_rejected')
    review_note(server,vault,path,stale_text)
    before_missing = review_writes(work,path)
    variables.update(CCR_REVIEW_QUESTION=stale_question,CCR_REVIEW_DRAFT=stale_text)
    held = work / 'review-missing-source-held.md'
    require(not held.exists(), 'review_missing_source_backup_exists')
    def hide_source():
        (vault / path).rename(held)
        code, _ = request(server,'GET',endpoint)
        require(code == 404, 'review_missing_source_not_observed')
    try:
        results['missing'] = str(harness(config,work,'testReviewMissingSourceRejected',variables,
            on_ready=hide_source,ready_marker='CCR_REVIEW_MISSING_READY'))
    finally:
        if held.exists():
            require(not (vault / path).exists(), 'review_source_recreated_while_missing')
            held.rename(vault / path)
    review_note(server,vault,path,stale_text)
    cleared.append(review_journal(config,work,test_id,'rejected'))
    results['finalReopen'] = str(harness(config,work,'testReviewReopen',variables))
    final = review_note(server,vault,path,stale_text)
    require(final['sha256'] == current['sha256'] and final['modifiedAt'] == current['modifiedAt'],
            'review_rejected_operation_changed_note')
    require(review_writes(work,path) == before_missing, 'review_missing_source_submitted_write')
    review_note(server,vault,other_path,other_text)
    after = work / 'review-scene-after.json'
    copy_file(config,work,state,after)
    require(read(after) == read(baseline), 'review_changed_unrelated_scene')
    require(all(Path(result).is_dir() for result in results.values()), 'review_ui_xcresult_missing')
    proof = {'ui':results,'edited':edited,'rated':rated,'final':final,'metadata':grade,
             'draftJournal':pending,'clearedJournals':cleared,'sceneBefore':str(baseline),'sceneAfter':str(after),
             'otherNotePreserved':True,'scenePreserved':True,'singleRatingEffect':True,
             'gradeRequests':grade_writes,'wireEvidence':str(work / 'review-note-writes.jsonl'),
             'inputSource':'UIKit keyboard automation; not Apple Pencil'}
    write(work / 'review-functional-readback.json',proof)
    return proof

REVIEW_GRADES = {'again':('obsidianReviewAgain','5분',300),
                'hard':('obsidianReviewHard','10분',600),
                'good':('obsidianReviewGood','24시간',86400),
                'easy':('obsidianReviewEasy','48시간',172800)}
NORMAL68_SOURCE = {'commit':'14e941099ca5d27bb4c1df171849d601a14a1455',
                   'tree':'4c1081a9a0e154e4ce2980d80d6d29e69edf1499'}

def verify_review_grade(card, note, grade, started, finished):
    require(grade in REVIEW_GRADES, 'review_grade_not_allowed')
    headers = re.findall(r'^<!-- ccr-review-card:v1 (.+) -->$',note['text'],re.MULTILINE)
    require(len(headers) == 1, 'review_metadata_missing')
    metadata = json.loads(headers[0])
    require(isinstance(metadata,dict) and set(metadata) == set(card['metadata']) and
            metadata['cardID'] == card['metadata']['cardID'], 'review_card_identity_changed')
    event = metadata['eventID']
    require(isinstance(event,str) and str(uuid.UUID(event)) == event and
            event not in [card['metadata']['eventID'],metadata['cardID'],str(uuid.UUID(int=0))],
            'review_event_identity_invalid')
    require(type(metadata['ratedAt']) is int and type(metadata['dueAt']) is int and
            started <= metadata['ratedAt'] <= finished and
            metadata['dueAt'] - metadata['ratedAt'] == REVIEW_GRADES[grade][2],
            'review_selected_grade_interval_or_time_invalid:' + grade)
    expected = review_text(card,card['question'],card['answer'],metadata)
    require(note['text'].encode() == expected.encode() and note['sha256'] == sha(expected.encode()),
            'review_grade_original_bytes_changed')
    return metadata

def review_grade_runtime(config, work, test_id):
    deployed = read(work / 'deployment.json')
    require(all(deployed.get(k) == v for k,v in NORMAL68_SOURCE.items()) and
            deployed.get('testId') == test_id, 'review_diagnostic_source_mismatch')
    app = Path(deployed['app'])
    require(not app.is_symlink() and app.resolve().is_relative_to(work.resolve()),
            'review_diagnostic_artifact_not_owned')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == BUNDLE and
            info.get('CCRSourceCommit') == NORMAL68_SOURCE['commit'] and
            info.get('CCRSourceTree') == NORMAL68_SOURCE['tree'], 'review_diagnostic_artifact_source_mismatch')
    executable = app / info['CFBundleExecutable']
    require(executable.resolve().parent == app.resolve() and
            sha(executable.read_bytes()) == deployed.get('executableSHA256'), 'review_diagnostic_artifact_hash_mismatch')
    observed, evidence = runtime_readback(config,work,test_id)
    require(all(observed.get(k) == v for k,v in NORMAL68_SOURCE.items()) and
            observed.get('bundleID') == BUNDLE and
            observed.get('executableSHA256') == deployed['executableSHA256'],
            'review_diagnostic_runtime_mismatch')
    return {'source':NORMAL68_SOURCE,'executableSHA256':deployed['executableSHA256'],
            'readback':str(evidence),'readbackSha256':sha(Path(evidence).read_bytes())}

def accept_review_grades(config, work, server, vault, test_id, normal68_evidence):
    """부모의 승인된 격리 기기 구간에서만 호출한다. 기존 accept 전체를 대체하지 않는다.

    부모가 기존 relay_runtime, canonical encoder, scene/context를 준비하고 같은 work를 전달한다.
    반환·실패 뒤 기존 cleanup(config, work, service, vault, test_id, before)을 finally에서 실행한다.
    normal68_evidence는 부모의 normal68-observation.json이다. normal 앱을 실행하지 않는다.
    """
    lease(config)
    require(not vault.is_symlink() and vault.resolve() == work.resolve() / 'isolated-vault',
            'review_grade_vault_not_owned')
    proof_path = work / 'review-four-grades-readback.json'
    require(not proof_path.exists(), 'review_grade_proof_already_exists')
    normal = read(normal68_evidence)
    require(type(normal.get('build')) is int and normal['build'] == 68 and
            normal.get('source') == NORMAL68_SOURCE['commit'] and normal.get('tree') == NORMAL68_SOURCE['tree'] and
            normal.get('normalBundle') == USER_BUNDLE and normal.get('normalInstalled') is True and
            normal.get('installedVersionReadback') is True, 'review_normal68_source_proof_missing')
    runtime_before = review_grade_runtime(config,work,test_id)
    state = 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state/CanvasScene.json'
    baseline = work / 'review-grades-scene-before.json'
    copy_file(config,work,state,baseline)
    rows = []; events = set()
    for grade, (button_id, interval, _) in REVIEW_GRADES.items():
        card = review_fixture(test_id + '-' + grade)
        card['metadata'] = dict(card['metadata'],cardID=str(uuid.uuid5(uuid.UUID(test_id),grade + ':card')),
                                eventID=str(uuid.uuid5(uuid.UUID(test_id),grade + ':seed')))
        path = card['path']; endpoint = '/vault/note?' + urllib.parse.urlencode({'path':path})
        original = review_text(card,card['question'],card['answer'],card['metadata'])
        code, _ = request(server,'GET',endpoint)
        require(code == 404, 'review_fixture_already_exists')
        code, _ = request(server,'PUT',endpoint,{'baseSha256':None,'text':original})
        require(code == 200, 'review_fixture_seed_failed')
        seed = review_note(server,vault,path,original)
        variables = {'CCR_REVIEW_NOTE':path,'CCR_REVIEW_QUESTION':card['question'],
                     'CCR_REVIEW_ANSWER':card['answer'],'CCR_REVIEW_DRAFT':original,
                     'CCR_REVIEW_GRADE_BUTTON_ID':button_id,'CCR_REVIEW_GRADE_INTERVAL':interval}
        before = review_writes(work,path)
        started = int(time.time())
        results = {'grade':str(harness(config,work,'testReviewSelectedGrade',variables))}
        finished = int(time.time())
        rated = review_note(server,vault,path)
        metadata = verify_review_grade(card,rated,grade,started,finished)
        require(metadata['eventID'] not in events, 'review_event_reused_across_grades')
        events.add(metadata['eventID'])
        grade_writes = [{'path':path,'status':200,'baseSha256':seed['sha256'],'textSha256':rated['sha256']}]
        require(review_writes(work,path) == before + grade_writes, 'review_duplicate_or_failed_grade_request')
        variables['CCR_REVIEW_DRAFT'] = rated['text']
        stop_owned(config,work)
        results['reopen'] = str(harness(config,work,'testReviewReopen',variables))
        reopened = review_note(server,vault,path,rated['text'])
        require(reopened == rated and review_writes(work,path) == before + grade_writes,
                'review_reopen_repeated_grade_request')
        remote_card = dict(card,question=card['question'] + ' / Mac 외부 질문',
                           answer=card['answer'] + ' / Mac 외부 답 👩🏽‍💻')
        remote_text = review_text(remote_card,remote_card['question'],remote_card['answer'],metadata)
        def remote_update():
            code, _ = request(server,'PUT',endpoint,{'baseSha256':rated['sha256'],'text':remote_text})
            require(code == 200, 'review_remote_update_failed')
            review_note(server,vault,path,remote_text)
        remote_variables = dict(variables,CCR_REVIEW_REMOTE_QUESTION=remote_card['question'],
                                CCR_REVIEW_REMOTE_ANSWER=remote_card['answer'],CCR_REVIEW_REMOTE_TEXT=remote_text)
        results['live'] = str(harness(config,work,'testReviewLiveRemoteRevision',remote_variables,
            on_ready=remote_update,ready_marker='CCR_REVIEW_LIVE_READY'))
        remote = review_note(server,vault,path,remote_text)
        expected_writes = before + grade_writes + [{'path':path,'status':200,
            'baseSha256':rated['sha256'],'textSha256':remote['sha256']}]
        variables.update(CCR_REVIEW_QUESTION=remote_card['question'],CCR_REVIEW_ANSWER=remote_card['answer'],
                         CCR_REVIEW_DRAFT=remote_text)
        stop_owned(config,work)
        results['remoteReopen'] = str(harness(config,work,'testReviewReopen',variables))
        final = review_note(server,vault,path,remote_text)
        require(verify_review_grade(remote_card,final,grade,started,finished) == metadata and final == remote,
                'review_final_metadata_or_digest_changed')
        require(review_writes(work,path) == expected_writes, 'review_live_or_reopen_extra_write')
        require(all(Path(result).is_dir() for result in results.values()), 'review_ui_xcresult_missing')
        rows.append({'grade':grade,'buttonID':button_id,'interval':interval,'path':path,'metadata':metadata,
                     'ratedAtRange':[started,finished],'seedSha256':seed['sha256'],'ratedSha256':rated['sha256'],
                     'finalSha256':final['sha256'],'final':final,'gradeRequests':grade_writes,'writes':expected_writes,
                     'additionalRatingWrites':0,'ui':results})
    for row in rows:
        require(review_note(server,vault,row['path']) == row['final'] and
                review_writes(work,row['path']) == row['writes'], 'review_cross_grade_effect')
        require(all(Path(result).is_dir() for result in row['ui'].values()), 'review_ui_xcresult_missing')
    after = work / 'review-grades-scene-after.json'
    copy_file(config,work,state,after)
    require(read(after) == read(baseline), 'review_changed_unrelated_scene')
    runtime_after = review_grade_runtime(config,work,test_id)
    require(runtime_before['executableSHA256'] == runtime_after['executableSHA256'], 'review_diagnostic_generation_changed')
    proof = {'grades':rows,'normalSourceProof':{'path':str(normal68_evidence),
             'sha256':sha(Path(normal68_evidence).read_bytes()),'source':NORMAL68_SOURCE,'build':68},
             'diagnosticBefore':runtime_before,'diagnosticAfter':runtime_after,'diagnosticGradesAccepted':True,
             'normalAppAccepted':False,
             'fullAdapterAccepted':False,'scope':'diagnostic four-grade check; cleanup and full accept remain parent-owned',
             'wireEvidence':str(work / 'review-note-writes.jsonl'),'scenePreserved':True,
             'inputSource':'UIKit keyboard automation; not Apple Pencil'}
    write(proof_path,proof)
    return proof

def relay_runtime(config, work, source):
    if config.get('_runtimeBundle') == USER_BUNDLE:
        receipt = pinned_json(config, 'existingRelayReceipt', 'existingRelayReceiptSHA256')
        context = read(test_context_path(config, work))
        require(receipt.get('schema') == 'ccr.existing-ipad-test-relay/v1' and
                receipt.get('testId') == context['id'] and receipt.get('address') == context['relayAddress'] and
                urllib.parse.urlsplit(receipt['address']).port == 8793, 'existing_relay_context_mismatch')
        lifecycle = runpy.run_path('/Users/ambrion/.local/bin/bt-service-lifecycle')
        current = read(lifecycle['LEASES'] / (receipt['leaseId'] + '.json'))
        require(current.get('owner') == OWNER and current.get('serviceId') == 'ccr-ipad-integration-relay-8793' and current.get('generation') == source['commit'] and
                all(current.get(k) == receipt.get(k) for k in ['leaseId','owner','serviceId','generation','pid','birth']) and
                lifecycle['is_live'](current) and lifecycle['expiry'](current) > lifecycle['now'](),
                'existing_relay_lease_not_current')
        private = pinned_json(receipt, 'configurationPath', 'configurationSHA256')
        argv = current.get('argv', [])
        require(len(argv) == 3 and Path(argv[1]).resolve() == (Path(config['repo']) / 'Scripts/ipad-test-runtime/relay.js').resolve() and
                Path(argv[2]).resolve() == Path(receipt['configurationPath']).resolve() and
                private.get('vault') == receipt.get('vault') and private.get('token') == context['token'] and
                private.get('host') == urllib.parse.urlsplit(context['relayAddress']).hostname and private.get('port') == 8793 and
                current.get('pid') in lifecycle['listener_pids'](8793), 'existing_relay_configuration_mismatch')
        vault = Path(receipt['vault']).resolve()
        require(vault.is_dir() and not Path(receipt['vault']).is_symlink() and not (work / 'isolated-vault').is_symlink() and
                vault.is_relative_to(work.resolve()) and
                vault == (work / 'isolated-vault' / context['id']).resolve(), 'existing_relay_vault_not_uuid_owned')
        require(Path(private.get('relayRepo','')).resolve() == Path(config['relayRepo']).resolve() and
                private.get('noteAudit') == str(work / 'review-note-writes.jsonl'), 'existing_relay_source_or_audit_mismatch')
        for key in ['store','snapshot','hidden']:
            path = Path(private.get(key,''))
            require(not path.is_symlink() and path.resolve().is_relative_to(work.resolve()), 'existing_relay_storage_not_owned')
        encoder = Path(receipt['encoder']).resolve()
        require(sha(encoder.read_bytes()) == receipt['encoderSHA256'] and
                receipt.get('encoderSourceCommit') == source['commit'], 'existing_encoder_source_mismatch')
        relay_repo = Path(config['relayRepo']).resolve()
        require(command(['git','rev-parse','HEAD'],cwd=relay_repo).strip() == config['relayCommit'] and
                not command(['git','status','--porcelain','--untracked-files=no'],cwd=relay_repo).strip(), 'relay_source_mismatch')
        server = {'address':context['relayAddress'],'token':context['token'],'encoder':encoder}
        require(request(server,'GET','/vault/entries')[0] == 200, 'existing_relay_not_ready')
        return server, vault, dict(current, borrowed=True)
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
            'snapshot': str(snapshot), 'hidden': str(hidden), 'token': ctx['token'], 'host': config['relayHost'], 'port': config['relayPort'],
            'noteAudit':str(work / 'review-note-writes.jsonl')}
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
    if service.get('borrowed'):
        results['relayPreserved'] = True
    if not service.get('borrowed'):
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
                     '--domain-identifier', config.get('_runtimeBundle',BUNDLE), '--source', empty, '--destination', 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state',
                     '--remove-existing-content', 'true'], work / 'reset.log', 60)
        except Held:
            pass
        inventory = work / ('reset-device-files-' + str(time.time_ns()) + '.json')
        device(config, ['info', 'files', '--domain-type', 'appDataContainer', '--domain-identifier', config.get('_runtimeBundle',BUNDLE),
                        '--json-output', str(inventory)], work / 'reset-inventory.log')
        observed = read(inventory)['result']
        require(observed['domainIdentifier'] == config.get('_runtimeBundle',BUNDLE), 'device_reset_domain_mismatch')
        prefix = 'Library/Application Support/CCRIntegrationTests/' + test_id + '/state'
        require(not any(row['relativePath'].startswith(prefix + '/') or
                        row['relativePath'] == prefix and not row['resources']['isDirectory']
                        for row in observed['files']), 'device_fixture_reset_failed')
        results['deviceStateEmpty'] = True
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['deviceStateEmpty'] = False
    try:
        expected_vault = work / 'isolated-vault' / test_id if service.get('borrowed') else None
        require((results.get('relayReleased') or results.get('relayPreserved')) and not vault.is_symlink() and
                vault.resolve().is_relative_to(work.resolve()) and not (work / 'isolated-vault').is_symlink() and
                (vault.resolve() == expected_vault.resolve() if expected_vault else vault.resolve().parent == work.resolve()), 'vault_cleanup_not_owned')
        shutil.rmtree(vault); vault.mkdir()
        results['vaultEmpty'] = not list(vault.iterdir())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['vaultEmpty'] = False
    try:
        results['originalDataPreserved'] = same_user_data(snapshots(config, work, 'user-after-reset'), before)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        results['originalDataPreserved'] = False
    write(work / 'reset-readback.json', results)
    return all(results.values())

def accept(config, work, source):
    deployed = prepared_runtime(config, work, source)
    config = dict(config, _runtimeBundle=USER_BUNDLE)
    lease(config)
    contract = acceptance_contract(config)
    require(all(deployed[k] == source[k] for k in source), 'deployment_source_mismatch')
    test_id = deployed['testId']; before = read(work / 'prepared-before.json')
    require(digest_value(before) == deployed.get('protectionBaselineSHA256'), 'prepared_baseline_changed')
    # 모든 요구 method와 원본 xctestrun을 fixture 쓰기 전에 검증한다.
    runner = verified_runner(config, work, RUNNER_CORE_METHODS)
    run_bytes = Path(config['existingXctestrun']).read_bytes()
    require(sha(run_bytes) == config['existingXctestrunSHA256'], 'existing_xctestrun_changed')
    destination_artifacts_run(plistlib.loads(run_bytes),runner,test_id)
    server, vault, service = relay_runtime(config, work, source)
    lifecycle = '/Users/ambrion/.local/bin/bt-service-lifecycle'
    accepted = False
    try:
        stop_owned(config, work)
        time.sleep(1)
        start = fixture(test_id)
        prior_status, prior = request(server, 'GET', '/vault/canvas?id=' + test_id)
        require(prior_status in (200, 404), 'fixture_lookup_failed')
        base = prior['noteSha256'] if prior_status == 200 else None
        if prior_status == 200:
            start['revision'] = prior['revision'] + 1
        code, saved = save_scene(server, start, pixel(), base); require(code == 200, 'fixture_seed_failed')
        (work / 'seed-state').mkdir(mode=0o700,exist_ok=True)
        write(work / 'seed-state/CanvasScene.json', start)
        copy_file(config, work, work / 'seed-state',
                  'Library/Application Support/CCRIntegrationTests/' + test_id + '/state', 'to', replace=True)
        copy_file(config, work, test_context_path(config, work),
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
        if not service.get('borrowed'):
            command([lifecycle, 'renew', '--owner', OWNER, '--ttl', '900', service['leaseId']], work / 'relay-renew.log')
        reverse = harness(config, work, 'testReopenRemoteRevision')
        rotation = accept_rotation(config, work, server, vault, test_id)
        comments = accept_comments(config, work, server, test_id)
        review = accept_review(config, work, server, vault, test_id)
        require(same_user_data(snapshots(config, work, 'user-after-accept'), before), 'original_data_changed')
        observed, runtime_evidence = runtime_readback(config, work, test_id)
        validate_runtime_code_images(observed,deployed['codeImages'],
            installed_normal(read(work / 'prepared-after-isolated.json'))['url'])
        require(all(observed.get(k) == source[k] for k in source) and observed.get('executableSHA256') == deployed['executableSHA256'], 'accepted_runtime_mismatch')
        proof = {'nativeResult': str(ui), 'reverseResult': str(reverse), 'vault': current, 'runtime': observed,
                 'rotation':rotation, 'comments':comments, 'review':review, 'originalPreserved': True}
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
    parser = argparse.ArgumentParser(); parser.add_argument('phase', choices=['deploy', 'accept', 'deploy-prepared']); parser.add_argument('--config', required=True)
    args = parser.parse_args()
    try:
        if args.phase == 'deploy':
            single_app_installation_gate()
        config = read(args.config)
        output = Path(config['outputRoot']).resolve()
        approved = Path(json.loads(command(['/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad']))['path']).resolve()
        require(output.is_relative_to(approved) and output != approved, 'output_path_not_routed')
        require(ipaddress.ip_address(config['relayHost']).is_private and ipaddress.ip_address(config['relayHost']).version == 4,
                'relay_host_not_private_ipv4')
        require(int(config['relayPort']) == 8793, 'relay_port_not_registered_integration_port')
        source = identity(config); work = output / source['commit']
        require(not work.is_symlink() and work.resolve().parent == output, 'work_path_escapes_routed_root')
        work.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.mkdir(parents=True, exist_ok=True)
        with (output / 'device-and-build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lease(config)
            guard = command(['/Users/ambrion/.local/bin/codex-source-guard', 'capture', '--repo', config['repo'], '--ref', 'integration/ccr-ipad'])
            guard_data = json.loads(guard)
            require(guard_data.get('repository') == 'github.com/plamyth/sill' and
                    all(guard_data.get(k) == source[k] for k in source), 'source_guard_identity_mismatch')
            write(work / 'source-guard.json', guard_data)
            result = deploy_prepared(config, work, source) if args.phase == 'deploy-prepared' else (
                deploy(config, work, source) if args.phase == 'deploy' else accept(config, work, source))
            require(identity(config) == source, 'source_changed_during_run')
            print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'held', 'reason': str(error) if isinstance(error, Held) else type(error).__name__}))
        return 2
    return 0

if __name__ == '__main__':
    sys.exit(main())

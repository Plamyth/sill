#!/usr/bin/env python3
"""기존 iPad 앱의 내부 TestFlight 후보만 읽기 전용으로 사전검사한다."""
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import runpy
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from xml.parsers.expat import ExpatError

import adapter

HOST_PROFILE_SHA256 = 'df7a4b0242b43fa8a7c8a8004bfa1c30305cf86543118ef36fa1beeb7cdd6af3'
APPLICATION_ID = adapter.NORMAL_TEAM + '.' + adapter.USER_BUNDLE
SOURCE_REF = 'integration/ccr-ipad'
SOURCE_REPOSITORY = 'github.com/plamyth/sill'
SOURCE_GUARD = '/Users/ambrion/.local/bin/codex-source-guard'
require = adapter.require


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate_json_key')
        value[key] = item
    return value


def json_bytes(data):
    value = json.loads(data, object_pairs_hook=unique_object)
    require(isinstance(value, dict), 'json_object_required')
    return value


def stream_hash(stream):
    digest = hashlib.sha256()
    for data in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(data)
    return digest.hexdigest()


def file_hash(path):
    with Path(path).open('rb') as stream:
        return stream_hash(stream)


def regular(path):
    path = Path(path).absolute()
    require(not any(p.is_symlink() for p in (path, *path.parents)) and path.is_file(),
            'regular_input_required')
    return path


def pinned(config, name):
    require(name in config, 'missing_input:' + name)
    ref = config[name]
    require(isinstance(ref, dict) and set(ref) == {'path', 'sha256'} and
            isinstance(ref['sha256'], str) and re.fullmatch('[0-9a-f]{64}', ref['sha256']),
            'invalid_pin:' + name)
    path = regular(ref['path'])
    data = path.read_bytes()
    require(adapter.sha(data) == ref['sha256'], 'input_changed:' + name)
    return path, data


def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, timeout=60, env=adapter.ENV)
    require(result.returncode == 0, 'command_failed:' + Path(str(args[0])).name)
    return result.stdout


def source_identity(config, capture):
    require(capture.get('schema') == 'codex.source-identity/v1' and
            capture.get('repository') == SOURCE_REPOSITORY and capture.get('ref') == SOURCE_REF and
            capture.get('remote') == 'origin', 'official_source_capture_required')
    repo = Path(config['repo']).resolve()
    require(Path(capture['source_worktree']).resolve() == repo, 'source_worktree_mismatch')
    source = adapter.identity({'repo': str(repo)})
    identity = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'ipad-source-identity.py'))['identity']
    require(identity(repo) == (source['commit'], source['tree']) and
            all(source[key] == capture.get(key) for key in ('commit', 'tree')),
            'official_source_readback_mismatch')
    verified = json_bytes(run([SOURCE_GUARD, 'verify', '--repo', repo,
                               '--receipt', config['sourceCapture']['path']]))
    require(verified.get('ok') is True and verified.get('commit') == source['commit'] and
            verified.get('repository') == SOURCE_REPOSITORY and verified.get('ref') == SOURCE_REF and
            verified.get('remote_verification') == 'target_live' and
            Path(verified['target_worktree']).resolve() == repo, 'source_guard_readback_failed')
    return source


def preserved_files(root):
    root = Path(root).absolute()
    require(root.is_dir() and not any(p.is_symlink() for p in (root, *root.parents)),
            'preservation_directory_required')
    hashes = adapter.artifact_files(root)
    return {name: {'bytes': (root / name).stat().st_size, 'sha256': digest}
            for name, digest in hashes.items()}


def preservation(config):
    _, raw = pinned(config, 'preservationManifest')
    manifest = json_bytes(raw)
    _, raw = pinned(config, 'preservationBefore')
    before = json_bytes(raw)
    expected = manifest['files']
    require(isinstance(expected, dict) and len(expected) == manifest.get('fileCount') == 55 and
            manifest.get('independentRestoreMatches') is True and manifest.get('keychainExported') is False and
            manifest.get('appRemoved') is False and before.get('deletionPerformed') is False and
            before.get('bundle') == adapter.USER_BUNDLE and before.get('installedBuild') == '77',
            'preservation_baseline_required')
    original = Path(config['preservedRoot']).resolve()
    restored = Path(config['restoredRoot']).resolve()
    require(original != restored and not original.is_relative_to(restored) and
            not restored.is_relative_to(original), 'independent_restore_required')
    archive, _ = pinned(config, 'preservationArchive')
    require(str(archive) == manifest['archive'] and
            file_hash(archive) == manifest['archiveSHA256'], 'preservation_archive_changed')
    actual = preserved_files(config['preservedRoot'])
    require(actual == expected and preserved_files(config['restoredRoot']) == expected and
            sum(item['bytes'] for item in actual.values()) == manifest['bytes'],
            'preservation_or_restore_changed')
    archived = {}
    with tarfile.open(archive, 'r:*') as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and '..' not in path.parts and
                    path.parts and path.parts[0] == original.name and
                    (member.isdir() or member.isfile()), 'unsafe_preservation_tar')
            if member.isfile():
                name = str(PurePosixPath(*path.parts[1:]))
                require(name not in archived, 'duplicate_preservation_tar_entry')
                with stream.extractfile(member) as data:
                    archived[name] = {'bytes': member.size,
                                      'sha256': stream_hash(data)}
    require(archived == expected, 'preservation_tar_manifest_mismatch')
    for name, field, pin in [
        ('Library/Application Support/CanvasScene.json', 'sceneSHA256', 'originalScene'),
        ('Library/Preferences/' + adapter.USER_BUNDLE + '.plist', 'preferencesSHA256', 'originalPreferences')]:
        _, raw = pinned(config, pin)
        require(actual.get(name, {}).get('sha256') == before[field] == adapter.sha(raw),
                'original_scene_or_preferences_changed')
    return {'files': 55, 'archiveSHA256': manifest['archiveSHA256'],
            'manifestSHA256': adapter.digest_value(expected), 'independentRestoreRechecked': True,
            'scope': 'existing-local-build77-backup-only', 'newDevicePreservationVerified': False}


def effective_groups(entitlements):
    groups = entitlements.get('keychain-access-groups', [entitlements.get('application-identifier')])
    require(isinstance(groups, list) and groups and all(isinstance(g, str) for g in groups) and
            len(groups) == len(set(groups)), 'invalid_app_keychain_groups')
    return set(groups)


def installed_baseline(config, work):
    _, raw = pinned(config, 'installedIdentity')
    reference = json_bytes(raw)
    app = Path(reference['app'])
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == adapter.USER_BUNDLE and info.get('CFBundleVersion') == '77',
            'installed77_artifact_mismatch')
    entitlements = adapter.signed_entitlements(app, work, 'installed77')
    raw = run(['/usr/bin/codesign', '--display', '--entitlements', ':-', app])
    require(adapter.sha(raw) == reference.get('rawEntitlementsSHA256') and
            reference.get('applicationIdentifier') == entitlements.get('application-identifier') == APPLICATION_ID and
            reference.get('teamIdentifier') == entitlements.get('com.apple.developer.team-identifier') == adapter.NORMAL_TEAM and
            reference.get('keychainAccessGroups') == entitlements.get('keychain-access-groups') and
            reference.get('getTaskAllow') == entitlements.get('get-task-allow') and
            effective_groups(entitlements) == {APPLICATION_ID}, 'installed77_identity_changed')
    _, raw = pinned(config, 'installedMetadata')
    matches = [row for row in json_bytes(raw)['result']['apps']
               if row.get('bundleIdentifier') == adapter.USER_BUNDLE]
    require(len(matches) == 1 and matches[0].get('bundleVersion') == '77', 'installed77_metadata_mismatch')
    return entitlements


def profile_checks(profile, entitlements, baseline, leaf, now):
    require(entitlements.get('application-identifier') == APPLICATION_ID and
            entitlements.get('com.apple.developer.team-identifier') == adapter.NORMAL_TEAM and
            entitlements.get('get-task-allow') is False and
            entitlements.get('beta-reports-active') is True, 'candidate_entitlements_mismatch')
    require(effective_groups(entitlements) == effective_groups(baseline) == {APPLICATION_ID},
            'candidate_keychain_continuity_mismatch')
    allowed = profile.get('Entitlements', {})
    expiry = profile.get('ExpirationDate')
    if isinstance(expiry, dt.datetime) and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(profile.get('TeamIdentifier') == [adapter.NORMAL_TEAM] and
            profile.get('ApplicationIdentifierPrefix') == [adapter.NORMAL_TEAM] and
            allowed.get('application-identifier') == APPLICATION_ID and
            allowed.get('com.apple.developer.team-identifier') == adapter.NORMAL_TEAM and
            allowed.get('get-task-allow') is False and allowed.get('beta-reports-active') is True and
            'ProvisionedDevices' not in profile and 'ProvisionsAllDevices' not in profile and
            isinstance(expiry, dt.datetime) and expiry > now and
            isinstance(profile.get('UUID'), str) and profile['UUID'], 'app_store_profile_required')
    patterns = allowed.get('keychain-access-groups', [])
    require(isinstance(patterns, list) and patterns and all(isinstance(p, str) for p in patterns) and
            all(any(fnmatch.fnmatchcase(group, pattern) for pattern in patterns)
                for group in effective_groups(entitlements)), 'profile_keychain_not_authorized')
    require(isinstance(profile.get('DeveloperCertificates'), list) and leaf and
            leaf in profile['DeveloperCertificates'], 'profile_signing_certificate_mismatch')
    return {'uuid': profile['UUID'], 'expiresAt': expiry.isoformat(),
            'signingCertificateSHA256': adapter.sha(leaf), 'type': 'app-store'}


def unpack_ipa(ipa, work):
    destination = work / 'unpacked'
    destination.mkdir()
    with zipfile.ZipFile(ipa) as stream:
        seen = set()
        for item in stream.infolist():
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in item.filename and
                    path.parts and item.filename not in seen and
                    not stat.S_ISLNK(item.external_attr >> 16), 'unsafe_ipa_entry')
            seen.add(item.filename)
        stream.extractall(destination)
    apps = list((destination / 'Payload').glob('*.app'))
    require(len(apps) == 1 and apps[0].name == 'Sill.app', 'canonical_ipa_app_required')
    require(not list(apps[0].rglob('*.appex')) and not list(apps[0].rglob('*.app')),
            'additional_app_or_extension_not_supported')
    return apps[0]


def privacy_checks(app, release_script):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = info.get('CFBundleExecutable', '')
    require(isinstance(executable, str) and re.fullmatch('[A-Za-z0-9_.-]+', executable),
            'privacy_executable_invalid')
    binary = regular(app / executable)
    # The shared analyzer masks nm/otool failures with || true; probe them before reusing it.
    run(['/usr/bin/nm', '-u', binary])
    run(['/usr/bin/otool', '-v', '-s', '__TEXT', '__objc_methname', binary])
    declared, manifests = set(), {}
    for path in sorted(app.rglob('PrivacyInfo.xcprivacy')):
        raw = regular(path).read_bytes()
        manifests[str(path.relative_to(app))] = adapter.sha(raw)
        value = plistlib.loads(raw)
        entries = value.get('NSPrivacyAccessedAPITypes', [])
        require(isinstance(entries, list), 'privacy_api_declarations_invalid')
        for entry in entries:
            category = entry.get('NSPrivacyAccessedAPIType', '')
            reasons = entry.get('NSPrivacyAccessedAPITypeReasons', [])
            require(isinstance(category, str) and re.fullmatch('NSPrivacyAccessedAPICategory[A-Za-z]+', category) and
                    isinstance(reasons, list) and reasons and
                    all(isinstance(reason, str) and re.fullmatch('[0-9A-F]{4}\\.[0-9]+', reason) for reason in reasons),
                    'privacy_nonempty_reasons_required')
            declared.add(category.removeprefix('NSPrivacyAccessedAPICategory'))
    require(manifests and 'PrivacyInfo.xcprivacy' in manifests, 'embedded_privacy_manifest_required')
    shell = ('source "$1"; say() { printf "%s\\n" "$*"; }; '
             'warn() { printf "PRIVACY_REQUIRED_REASON_WARNING\\n" >&2; return 2; }; '
             'check_required_reasons "$2"')
    result = subprocess.run(['/bin/bash', '-c', shell, 'candidate-privacy', str(release_script), str(app)],
                            capture_output=True, timeout=60, env=adapter.ENV)
    output = result.stdout.decode()
    none = "Required-reason APIs: the binary uses none of Apple's list"
    prefix = 'Required-reason APIs in the binary: '
    if output.strip() == none:
        used = []
    else:
        require(output.startswith(prefix) and '; declared: ' in output, 'privacy_analysis_output_invalid')
        used = re.findall(r'(?:^|; )([A-Za-z]+(?: or [A-Za-z]+)*) \(', output[len(prefix):].split('; declared: ', 1)[0])
        require(used, 'privacy_analysis_output_invalid')
    missing = [category for category in used if not set(category.split(' or ')) & declared]
    require(not missing, 'privacy_required_reason_missing:' + ','.join(missing))
    require(result.returncode == 0 and not result.stderr, 'privacy_warning_or_analysis_failure')
    return {'analysis': 'release-ios.sh/check_required_reasons', 'usedCategories': used,
            'declaredCategories': sorted(declared), 'manifestSHA256': manifests, 'warnings': 0,
            'scope': 'existing-required-reason-api-scan; reason-semantics-and-Apple-review-not-attested'}


def export_binding(config, source, ipa_hash, info, files, entitlements, profile_result, leaf):
    options_path, raw = pinned(config, 'exportOptions')
    options = plistlib.loads(raw)
    exported_path, raw = pinned(config, 'exportedOptions')
    exported = plistlib.loads(raw)
    for value in (options, exported):
        require(value.get('method') == 'app-store-connect' and value.get('destination') == 'export' and
                value.get('teamID') == adapter.NORMAL_TEAM and value.get('testFlightInternalTestingOnly') is True and
                value.get('manageAppVersionAndBuildNumber') is False, 'internal_only_export_options_required')
    require(options_path != exported_path and exported_path.name == 'ExportOptions.plist' and
            exported_path.parent == Path(config['ipa']['path']).absolute().parent,
            'native_export_options_binding_required')
    _, raw = pinned(config, 'exportIntent')
    intent = json_bytes(raw)
    _, raw = pinned(config, 'exportResult')
    receipt = json_bytes(raw)
    _, raw = pinned(config, 'exportReadback')
    readback = json_bytes(raw)
    _, log = pinned(config, 'exportLog')
    for value in (intent, receipt):
        require(value.get('exportOptionsSHA256') == config['exportOptions']['sha256'] and
                value.get('sourceCommit') == source['commit'] and value.get('sourceTree') == source['tree'] and
                value.get('profileUUID') == profile_result['uuid'] and
                value.get('signingCertificateSHA1') == hashlib.sha1(leaf).hexdigest().upper() and
                value.get('internalTestingOnly') is True and value.get('upload') is False and
                value.get('privateKeyExported') is False and value.get('hostOrDeviceChanged') is False,
                'export_intent_or_result_mismatch')
    require(receipt.get('exit') == 0 and intent.get('archive') == receipt.get('archive') and
            b'** EXPORT SUCCEEDED **' in log, 'native_export_success_required')
    require(readback.get('IPASHA256') == ipa_hash and
            Path(readback['IPA']).absolute() == Path(config['ipa']['path']).absolute() and
            readback.get('IPABytes') == Path(config['ipa']['path']).stat().st_size and
            readback.get('appManifest') == files and readback.get('appManifestSHA256') == adapter.digest_value(files) and
            readback.get('entitlements') == entitlements and readback.get('exportOptions') == options and
            readback.get('strictAppleSignatureVerified') is True and readback.get('AppStoreProfile') is True and
            readback.get('profileUUID') == profile_result['uuid'] and readback.get('ownerBootstrapSHA256') == HOST_PROFILE_SHA256 and
            readback.get('bundle') == info['CFBundleIdentifier'] and readback.get('build') == info['CFBundleVersion'] and
            readback.get('version') == info['CFBundleShortVersionString'] and
            all(readback.get(key) == source[key] for key in ('commit', 'tree')),
            'export_readback_binding_required')
    summary_path, raw = pinned(config, 'distributionSummary')
    require(summary_path == exported_path.parent / 'DistributionSummary.plist', 'native_summary_path_mismatch')
    summary = plistlib.loads(raw)
    require(set(summary) == {'Sill.ipa'} and isinstance(summary['Sill.ipa'], list) and
            len(summary['Sill.ipa']) == 1, 'native_distribution_summary_required')
    item = summary['Sill.ipa'][0]
    require(item.get('name') == 'Sill.app' and item.get('buildNumber') == info['CFBundleVersion'] and
            item.get('versionNumber') == info['CFBundleShortVersionString'] and item.get('entitlements') == entitlements and
            item.get('team', {}).get('id') == adapter.NORMAL_TEAM and item.get('profile', {}).get('UUID') == profile_result['uuid'] and
            item.get('certificate', {}).get('SHA1') == hashlib.sha1(leaf).hexdigest().upper() and
            item.get('certificate', {}).get('type') == 'Apple Distribution', 'native_summary_artifact_mismatch')
    require(exported.get('provisioningProfiles') == options.get('provisioningProfiles') ==
            {adapter.USER_BUNDLE: profile_result['uuid']} and
            exported.get('signingCertificate') == options.get('signingCertificate') == item['certificate']['SHA1'],
            'native_options_signing_binding_mismatch')
    packaging_path, packaging = pinned(config, 'packagingLog')
    require(packaging_path == exported_path.parent / 'Packaging.log' and b'Sill.ipa' in packaging,
            'native_packaging_evidence_required')
    archive_info = Path(receipt['archive']) / 'Products/Applications/Sill.app/Info.plist'
    archived = plistlib.loads(regular(archive_info).read_bytes())
    require(all(archived.get(key) == info.get(key) for key in
                ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString',
                 'CCRSourceCommit', 'CCRSourceTree', 'CCRSourceIdentityVerified')),
            'export_archive_source_mismatch')
    return {'internalOnly': True, 'evidence': 'native-export-options-and-success-log-bound-to-ipa',
            'exportResultSHA256': config['exportResult']['sha256'],
            'ipaEmbeddedInternalOnlyFlagVerified': False}


def preflight(config, work):
    require(config.get('schema') == 'ccr.ipad-testflight-preflight-input/v1', 'input_schema_required')
    require(config.get('externalTestersAllowed') is False, 'external_testers_forbidden')
    for name in ('repo', 'preservedRoot', 'restoredRoot'):
        require(isinstance(config.get(name), str) and config[name], 'missing_or_invalid_input:' + name)
    pins = ('ipa', 'sourceCapture', 'buildReceipt', 'hostProfile', 'installedIdentity', 'installedMetadata',
            'preservationManifest', 'preservationBefore', 'preservationArchive', 'originalScene',
            'originalPreferences', 'exportOptions', 'exportedOptions', 'exportIntent', 'exportResult',
            'exportReadback', 'exportLog', 'distributionSummary', 'packagingLog')
    inputs = {name: pinned(config, name) for name in pins}
    source = source_identity(config, json_bytes(inputs['sourceCapture'][1]))
    saved = preservation(config)
    baseline = installed_baseline(config, work)
    require(config['hostProfile']['sha256'] == HOST_PROFILE_SHA256, 'approved_host_profile_required')
    validate = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'provision-owner-bootstrap.py'))['validate']
    validate(inputs['hostProfile'][1])
    app = unpack_ipa(inputs['ipa'][0], work)
    files = adapter.artifact_files(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == adapter.USER_BUNDLE and
            info.get('CCRSourceIdentityVerified') is True and
            all(info.get('CCRSource' + key.title()) == source[key] for key in ('commit', 'tree')),
            'candidate_info_source_mismatch')
    require(adapter.version_tuple(info.get('CFBundleVersion')) >= (78, 0, 0), 'candidate_build_below_78')
    require(files.get('CCR-OwnerMacBootstrap.json') == HOST_PROFILE_SHA256, 'candidate_host_profile_mismatch')
    build = json_bytes(inputs['buildReceipt'][1])
    require(build.get('exit') == 0 and build.get('sourceCommit') == source['commit'] and
            build.get('sourceTree') == source['tree'] and str(build.get('build')) == info['CFBundleVersion'] and
            build.get('officialProducerProfileSHA256') == HOST_PROFILE_SHA256, 'build_receipt_mismatch')
    require(info.get('CFBundleShortVersionString') == plistlib.loads(
            (Path(json_bytes(inputs['installedIdentity'][1])['app']) / 'Info.plist').read_bytes()
            ).get('CFBundleShortVersionString'), 'marketing_version_continuity_mismatch')
    entitlements = adapter.signed_entitlements(app, work, 'testflight-candidate')
    signing = (work / 'testflight-candidate-signature.log').read_text()
    require(re.search(r'^Authority=(?:Apple|iPhone) Distribution: .+$', signing, re.M),
            'apple_distribution_signature_required')
    cert_prefix = work / 'public-signing-cert-'
    run(['/usr/bin/codesign', '--display', '--extract-certificates=' + str(cert_prefix), app])
    leaf = regular(str(cert_prefix) + '0').read_bytes()
    run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', str(cert_prefix) + '0', '-noout', '-checkend', '0'])
    profile = plistlib.loads(run(['/usr/bin/security', 'cms', '-D', '-i', app / 'embedded.mobileprovision']))
    profile_result = profile_checks(profile, entitlements, baseline, leaf, dt.datetime.now(dt.timezone.utc))
    profile_result['sha256'] = files['embedded.mobileprovision']
    export = export_binding(config, source, config['ipa']['sha256'], info, files, entitlements, profile_result, leaf)
    privacy = privacy_checks(app, Path(config['repo']) / 'Scripts/release-ios.sh')
    require(source_identity(config, json_bytes(inputs['sourceCapture'][1])) == source, 'source_changed_during_preflight')
    require(preservation(config) == saved, 'preservation_changed_during_preflight')
    for name in pins:
        pinned(config, name)
    require(adapter.artifact_files(app) == files, 'extracted_candidate_changed')
    return {'schema': 'ccr.ipad-testflight-candidate-preflight/v1', 'kind': 'test-candidate-preflight',
            'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'candidatePreflightPassed': True,
            'scope': 'internal-testflight-candidate-only', 'source': source,
            'bundleIdentifier': adapter.USER_BUNDLE, 'team': adapter.NORMAL_TEAM,
            'build': info['CFBundleVersion'], 'ipaSHA256': config['ipa']['sha256'],
            'artifactManifestSHA256': adapter.digest_value(files), 'hostProfileSHA256': HOST_PROFILE_SHA256,
            'profile': profile_result, 'export': export, 'privacy': privacy, 'preservation': saved,
            'inputSHA256': {name: config[name]['sha256'] for name in pins},
            'deviceCalls': 0, 'uploadCalls': 0, 'signingCalls': 0, 'registryWrites': 0,
            'hostCalls': 0, 'accountCalls': 0, 'newAppOrRunner': False,
            'acceptance': 'not-performed; test-deployment/runtime-readback and all seven required checks remain'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--scratch-root', required=True, type=Path,
                        help='storage-route로 확인한 작업별 임시 출력 디렉터리')
    args = parser.parse_args(argv)
    try:
        config = json_bytes(regular(args.config).read_bytes())
        require(args.scratch_root.is_dir() and not args.scratch_root.is_symlink(), 'scratch_root_required')
        with tempfile.TemporaryDirectory(prefix='tf-preflight-', dir=args.scratch_root) as work:
            result = preflight(config, Path(work))
    except (ValueError, KeyError, TypeError, OSError, AttributeError, OverflowError, RuntimeError, EOFError, ExpatError,
            subprocess.SubprocessError, zipfile.BadZipFile, tarfile.TarError):
        error = sys.exc_info()[1]
        reason = str(error) if isinstance(error, adapter.Held) else 'missing_or_invalid_input:' + type(error).__name__
        result = {'schema': 'ccr.ipad-testflight-candidate-preflight/v1',
                  'kind': 'test-candidate-preflight', 'candidatePreflightPassed': False,
                  'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'scope': 'internal-testflight-candidate-only',
                  'reason': reason, 'artifactVerification': 'incomplete',
                  'deviceCalls': 0, 'uploadCalls': 0, 'signingCalls': 0, 'registryWrites': 0}
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())

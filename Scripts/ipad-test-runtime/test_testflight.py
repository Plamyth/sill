#!/usr/bin/env python3
import datetime as dt
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import adapter
import testflight as tf

COMMIT = '71091dfc01d909bb365973539940bdd4b3de4dd4'
TREE = '91c4a7eb68ba48456171e4c84e98976f1a0c8b35'
EVIDENCE = Path('/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/testflight-rollout-20261105')


def pin(path):
    return {'path': str(path), 'sha256': tf.file_hash(path)}


def local_preservation_config(root=EVIDENCE):
    names = {'preservationManifest': 'full-preservation-readback.json',
             'preservationBefore': 'preservation-before.json', 'preservationArchive': 'private-before.tar.gz',
             'originalScene': 'CanvasScene-before.json', 'originalPreferences': 'Preferences-before.plist'}
    return {**{key: pin(root / name) for key, name in names.items()},
            'preservedRoot': str(root / 'private-before'),
            'restoredRoot': str(root / 'independent-restore/private-before')}


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('CCR_TF_TEST_ROOT'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.config = {'schema': 'ccr.ipad-testflight-preflight-input/v1',
                       'externalTestersAllowed': False, 'repo': str(self.root / 'official')}
        self.calls = []
        self.commit, self.tree = COMMIT, TREE
        self.debug_entitlements = {'application-identifier': tf.APPLICATION_ID,
                                   'com.apple.developer.team-identifier': adapter.NORMAL_TEAM,
                                   'get-task-allow': True}
        self.entitlements = {**self.debug_entitlements, 'get-task-allow': False, 'beta-reports-active': True}
        self.leaf = b'public-distribution-certificate-fixture'
        self.profile = {'UUID': '30a6314d-1aaa-4bfc-b8b0-a9a346be5cee',
                        'TeamIdentifier': [adapter.NORMAL_TEAM],
                        'ApplicationIdentifierPrefix': [adapter.NORMAL_TEAM],
                        'ExpirationDate': dt.datetime(2099, 11, 4),
                        'DeveloperCertificates': [self.leaf],
                        'Entitlements': {**self.entitlements,
                                         'keychain-access-groups': [adapter.NORMAL_TEAM + '.*', 'com.apple.token']}}
        self.info = {'CFBundleIdentifier': adapter.USER_BUNDLE, 'CFBundleVersion': '78',
                     'CFBundleShortVersionString': '0.5.1', 'CFBundleExecutable': 'Sill',
                     'CCRSourceCommit': COMMIT, 'CCRSourceTree': TREE, 'CCRSourceIdentityVerified': True}
        self.baseline = self.root / 'Signed77/Sill.app'
        self.put(self.baseline / 'Info.plist', plistlib.dumps({**self.info, 'CFBundleVersion': '77'}))
        self.record('installedIdentity', {'app': str(self.baseline), 'applicationIdentifier': tf.APPLICATION_ID,
                    'teamIdentifier': adapter.NORMAL_TEAM, 'keychainAccessGroups': None, 'getTaskAllow': True,
                    'rawEntitlementsSHA256': adapter.sha(plistlib.dumps(self.debug_entitlements))})
        self.record('installedMetadata', {'result': {'apps': [
            {'bundleIdentifier': adapter.USER_BUNDLE, 'bundleVersion': '77'},
            {'bundleIdentifier': 'unrelated.app', 'bundleVersion': '1'}]}})
        self.record('sourceCapture', {'schema': 'codex.source-identity/v1', 'repository': tf.SOURCE_REPOSITORY,
                    'ref': tf.SOURCE_REF, 'remote': 'origin', 'commit': COMMIT, 'tree': TREE,
                    'source_worktree': self.config['repo']})
        self.record('buildReceipt', {'sourceCommit': COMMIT, 'sourceTree': TREE, 'build': 78,
                    'officialProducerProfileSHA256': tf.HOST_PROFILE_SHA256, 'exit': 0})
        self.host_data = (EVIDENCE / 'live-owner-profile-readback.json')
        if self.host_data.is_file():
            self.host = Path(json.loads(self.host_data.read_bytes())['path']).read_bytes()
        else:
            # The fixture remains fully offline when the user's public profile is absent.
            import base64
            key = bytes(32)
            self.host = json.dumps({'schema': 'ccr.owner-mac-bootstrap/v1', 'macID': '0' * 16,
                                   'fingerprint': base64.urlsafe_b64encode(key).decode().rstrip('='),
                                   'addresses': ['100.64.0.1'], 'remotePort': 8791}).encode()
        self.record('hostProfile', self.host)
        self.host_patch = patch.object(tf, 'HOST_PROFILE_SHA256', adapter.sha(self.host))
        self.host_patch.start()
        self.addCleanup(self.host_patch.stop)
        self.edit('buildReceipt', officialProducerProfileSHA256=tf.HOST_PROFILE_SHA256)
        self.options = {'method': 'app-store-connect', 'destination': 'export', 'teamID': adapter.NORMAL_TEAM,
                        'testFlightInternalTestingOnly': True, 'manageAppVersionAndBuildNumber': False,
                        'provisioningProfiles': {adapter.USER_BUNDLE: self.profile['UUID']},
                        'signingCertificate': tf.hashlib.sha1(self.leaf).hexdigest().upper()}
        self.record('exportOptions', plistlib.dumps(self.options), self.root / 'RequestedOptions.plist')
        self.record('exportedOptions', plistlib.dumps(self.options), self.root / 'Export/ExportOptions.plist')
        self.archive = self.root / 'Archive.xcarchive'
        self.put(self.archive / 'Products/Applications/Sill.app/Info.plist', plistlib.dumps(self.info))
        intent = {'archive': str(self.archive), 'sourceCommit': COMMIT, 'sourceTree': TREE,
                  'exportOptionsSHA256': self.config['exportOptions']['sha256'],
                  'profileUUID': self.profile['UUID'], 'signingCertificateSHA1': self.options['signingCertificate'],
                  'internalTestingOnly': True, 'privateKeyExported': False, 'hostOrDeviceChanged': False, 'upload': False}
        self.record('exportIntent', intent)
        self.record('exportResult', {**intent, 'exit': 0})
        self.record('exportLog', b'** EXPORT SUCCEEDED **\n')
        self.record('packagingLog', b'Packaging Sill.ipa\n', self.root / 'Export/Packaging.log')
        self.privacy = {'NSPrivacyAccessedAPITypes': [
            {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryFileTimestamp',
             'NSPrivacyAccessedAPITypeReasons': ['C617.1']}]}
        self.app_files = {'Info.plist': plistlib.dumps(self.info), 'CCR-OwnerMacBootstrap.json': self.host,
                          'PrivacyInfo.xcprivacy': plistlib.dumps(self.privacy),
                          'Sill': b'native-executable-fixture', 'embedded.mobileprovision': b'public-cms-fixture'}
        self.write_ipa()
        summary = {'Sill.ipa': [{'name': 'Sill.app', 'buildNumber': '78', 'versionNumber': '0.5.1',
                    'entitlements': self.entitlements, 'team': {'id': adapter.NORMAL_TEAM},
                    'profile': {'UUID': self.profile['UUID']},
                    'certificate': {'SHA1': self.options['signingCertificate'], 'type': 'Apple Distribution'}}]}
        self.record('distributionSummary', plistlib.dumps(summary), self.root / 'Export/DistributionSummary.plist')
        self.make_preservation()
        self.process = patch.object(subprocess, 'run', self.native_boundary)
        self.process.start()
        self.addCleanup(self.process.stop)

    def put(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def record(self, key, value, path=None):
        path = path or self.root / (key + '.json')
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.put(path, data)
        self.config[key] = pin(path)

    def edit(self, key, **values):
        path = Path(self.config[key]['path'])
        self.record(key, {**json.loads(path.read_bytes()), **values}, path)

    def write_ipa(self):
        path = self.root / 'Export/Sill.ipa'
        path.parent.mkdir(exist_ok=True)
        with zipfile.ZipFile(path, 'w') as stream:
            for name, data in self.app_files.items():
                stream.writestr('Payload/Sill.app/' + name, data)
        self.config['ipa'] = pin(path)
        files = {name: adapter.sha(data) for name, data in self.app_files.items()}
        self.record('exportReadback', {'IPA': str(path), 'IPASHA256': self.config['ipa']['sha256'],
                    'IPABytes': path.stat().st_size, 'appManifest': files,
                    'appManifestSHA256': adapter.digest_value(files), 'entitlements': self.entitlements,
                    'exportOptions': self.options, 'strictAppleSignatureVerified': True, 'AppStoreProfile': True,
                    'profileUUID': self.profile['UUID'], 'ownerBootstrapSHA256': tf.HOST_PROFILE_SHA256,
                    'bundle': self.info['CFBundleIdentifier'], 'build': self.info['CFBundleVersion'],
                    'version': self.info['CFBundleShortVersionString'], 'commit': COMMIT, 'tree': TREE})

    def make_preservation(self):
        original = self.root / 'private-before'
        restored = self.root / 'restored/private-before'
        data = {'Library/Application Support/CanvasScene.json': b'original scene',
                'Library/Preferences/' + adapter.USER_BUNDLE + '.plist': b'original preferences'}
        data.update({f'Documents/file{i}': str(i).encode() for i in range(53)})
        for name, raw in data.items():
            self.put(original / name, raw)
            self.put(restored / name, raw)
        archive = self.root / 'private-before.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            stream.add(original, arcname=original.name)
        self.config['preservationArchive'] = pin(archive)
        self.config.update(preservedRoot=str(original), restoredRoot=str(restored))
        files = tf.preserved_files(original)
        self.record('preservationManifest', {'archive': str(archive), 'archiveSHA256': tf.file_hash(archive),
                    'files': files, 'fileCount': 55, 'bytes': sum(v['bytes'] for v in files.values()),
                    'independentRestoreMatches': True, 'keychainExported': False, 'appRemoved': False})
        scene, prefs = list(data.values())[:2]
        self.record('originalScene', scene)
        self.record('originalPreferences', prefs)
        self.record('preservationBefore', {'bundle': adapter.USER_BUNDLE, 'installedBuild': '77',
                    'deletionPerformed': False, 'sceneSHA256': adapter.sha(scene), 'preferencesSHA256': adapter.sha(prefs)})

    def native_boundary(self, args, **kwargs):
        args = list(map(str, args))
        self.calls.append(args)
        tool = Path(args[0]).name
        stdout, stderr = b'', b''
        if tool == 'git':
            if 'status' in args or 'submodule' in args:
                stdout = b''
            elif 'branch' in args:
                stdout = tf.SOURCE_REF.encode()
            elif args[-1] == 'HEAD':
                stdout = self.commit.encode()
            elif args[-1] == 'HEAD^{tree}':
                stdout = self.tree.encode()
            else:
                raise AssertionError(args)
        elif tool == 'codex-source-guard':
            stdout = json.dumps({'ok': True, 'commit': self.commit, 'repository': tf.SOURCE_REPOSITORY,
                'ref': tf.SOURCE_REF, 'target_worktree': self.config['repo'], 'remote_verification': 'target_live'}).encode()
        elif tool == 'codesign':
            if '--verify' in args:
                self.assertIn('--strict', args)
                self.assertIn('anchor apple generic', args[args.index('--test-requirement') + 1])
            elif '--entitlements' in args:
                stdout = plistlib.dumps(self.debug_entitlements if Path(args[-1]) == self.baseline else self.entitlements)
            elif any(arg.startswith('--extract-certificates=') for arg in args):
                prefix = next(arg.split('=', 1)[1] for arg in args if arg.startswith('--extract-certificates='))
                Path(prefix + '0').write_bytes(self.leaf)
            else:
                stderr = (f'TeamIdentifier={adapter.NORMAL_TEAM}\nIdentifier={adapter.USER_BUNDLE}\n'
                          'Authority=Apple Distribution: fixture\n').encode()
        elif tool == 'security':
            self.assertEqual(args[1:4], ['cms', '-D', '-i'])
            stdout = plistlib.dumps(self.profile)
        elif tool == 'openssl':
            self.assertIn('-checkend', args)
        elif tool in ('nm', 'otool'):
            stdout = b'_fstat\n' if tool == 'nm' else b'__objc_methname\n'
        elif tool == 'bash':
            self.assertIn('check_required_reasons', args[2])
            stdout = b'Required-reason APIs in the binary: FileTimestamp (fstat); declared: FileTimestamp\n'
        else:
            raise AssertionError('unexpected tool: ' + repr(args))
        return subprocess.CompletedProcess(args, 0, stdout, stderr)

    def check(self):
        with tempfile.TemporaryDirectory(dir=self.root) as work:
            return tf.preflight(self.config, Path(work))

    def test_candidate_only_receipt_and_read_only_commands(self):
        receipt = self.check()
        self.assertTrue(receipt['candidatePreflightPassed'])
        self.assertEqual(receipt['kind'], 'test-candidate-preflight')
        self.assertNotIn('testAccepted', receipt)
        self.assertNotIn('productionEligible', receipt)
        self.assertFalse(receipt['preservation']['newDevicePreservationVerified'])
        self.assertTrue(receipt['export']['internalOnly'])
        self.assertEqual({Path(args[0]).name for args in self.calls},
                         {'git', 'codesign', 'security', 'openssl', 'codex-source-guard', 'nm', 'otool', 'bash'})

    def test_profile_allowlist_does_not_expand_actual_app_groups(self):
        self.assertTrue(self.check()['candidatePreflightPassed'])
        self.entitlements['keychain-access-groups'] = [tf.APPLICATION_ID, 'com.apple.token']
        with self.assertRaisesRegex(adapter.Held, 'keychain_continuity'):
            self.check()

    def test_explicit_default_group_preserves_effective_identity(self):
        baseline = {**self.debug_entitlements, 'keychain-access-groups': [tf.APPLICATION_ID]}
        candidate = {**self.entitlements, 'keychain-access-groups': [tf.APPLICATION_ID]}
        self.assertEqual(tf.effective_groups(candidate), tf.effective_groups(baseline))
        tf.profile_checks(self.profile, candidate, self.debug_entitlements, self.leaf, dt.datetime.now(dt.timezone.utc))

    def test_candidate_entitlement_failures(self):
        for key, value in [('application-identifier', 'OTHER.bundle'),
                           ('com.apple.developer.team-identifier', 'OTHERTEAM'),
                           ('get-task-allow', True), ('get-task-allow', None), ('beta-reports-active', False),
                           ('keychain-access-groups', ['OTHER.prefix']), ('keychain-access-groups', []),
                           ('keychain-access-groups', ['ZPTXHJ866D.*'])]:
            with self.subTest(key=key, value=value), self.assertRaises(adapter.Held):
                tf.profile_checks(self.profile, {**self.entitlements, key: value}, self.debug_entitlements,
                                  self.leaf, dt.datetime.now(dt.timezone.utc))

    def test_profile_failures(self):
        for key, value in [('ProvisionedDevices', []), ('ProvisionsAllDevices', False),
                           ('TeamIdentifier', ['OTHER']), ('ApplicationIdentifierPrefix', ['OLDPREFIX']),
                           ('ExpirationDate', dt.datetime(2000, 1, 1)), ('DeveloperCertificates', [b'other'])]:
            with self.subTest(key=key), self.assertRaises(adapter.Held):
                tf.profile_checks({**self.profile, key: value}, self.entitlements, self.debug_entitlements,
                                  self.leaf, dt.datetime.now(dt.timezone.utc))
        for key, value in [('application-identifier', 'ZPTXHJ866D.*'), ('get-task-allow', True),
                           ('beta-reports-active', False), ('keychain-access-groups', ['com.apple.token'])]:
            p = {**self.profile, 'Entitlements': {**self.profile['Entitlements'], key: value}}
            with self.subTest(key=key), self.assertRaises(adapter.Held):
                tf.profile_checks(p, self.entitlements, self.debug_entitlements, self.leaf, dt.datetime.now(dt.timezone.utc))

    def test_missing_and_changed_inputs_fail(self):
        for key in list(self.config):
            old = self.config.pop(key)
            with self.subTest(key=key), self.assertRaises((adapter.Held, KeyError)):
                self.check()
            self.config[key] = old
        for key, ref in self.config.items():
            if isinstance(ref, dict):
                path = Path(ref['path'])
                raw = path.read_bytes()
                path.write_bytes(raw + b'changed')
                with self.subTest(changed=key), self.assertRaises(adapter.Held):
                    self.check()
                path.write_bytes(raw)

    def test_external_testers_fail_before_native_calls(self):
        self.config['externalTestersAllowed'] = True
        with self.assertRaisesRegex(adapter.Held, 'external_testers_forbidden'):
            self.check()
        self.assertEqual(self.calls, [])

    def test_source_and_build_receipt_mismatch(self):
        self.edit('sourceCapture', commit='a' * 40)
        with self.assertRaisesRegex(adapter.Held, 'source_readback'):
            self.check()
        self.edit('sourceCapture', commit=COMMIT)
        self.edit('buildReceipt', sourceTree='b' * 40)
        with self.assertRaisesRegex(adapter.Held, 'build_receipt'):
            self.check()

    def test_self_declared_internal_only_is_insufficient(self):
        options = {**self.options, 'testFlightInternalTestingOnly': False}
        self.record('exportedOptions', plistlib.dumps(options), Path(self.config['exportedOptions']['path']))
        with self.assertRaisesRegex(adapter.Held, 'internal_only_export_options'):
            self.check()

    def test_native_summary_and_receipt_bound_to_artifact(self):
        self.edit('exportReadback', IPASHA256='0' * 64)
        with self.assertRaisesRegex(adapter.Held, 'readback_binding'):
            self.check()
        self.write_ipa()
        summary_path = Path(self.config['distributionSummary']['path'])
        summary = plistlib.loads(summary_path.read_bytes())
        summary['Sill.ipa'][0]['certificate']['SHA1'] = '0' * 40
        self.record('distributionSummary', plistlib.dumps(summary), summary_path)
        with self.assertRaisesRegex(adapter.Held, 'summary_artifact'):
            self.check()

    def test_original_restore_and_archive_are_rechecked(self):
        for root in ('preservedRoot', 'restoredRoot'):
            path = Path(self.config[root]) / 'Library/Application Support/CanvasScene.json'
            raw = path.read_bytes()
            path.write_bytes(b'changed scene')
            with self.subTest(root=root), self.assertRaisesRegex(adapter.Held, 'preservation_or_restore_changed'):
                self.check()
            path.write_bytes(raw)
        self.config['restoredRoot'] = self.config['preservedRoot']
        with self.assertRaisesRegex(adapter.Held, 'independent_restore_required'):
            self.check()

    def test_version_bundle_source_in_ipa(self):
        for key, value in [('CFBundleVersion', '77'), ('CFBundleIdentifier', 'other.bundle'),
                           ('CCRSourceCommit', 'a' * 40), ('CCRSourceIdentityVerified', False)]:
            saved = self.app_files['Info.plist']
            self.app_files['Info.plist'] = plistlib.dumps({**self.info, key: value})
            self.write_ipa()
            with self.subTest(key=key), self.assertRaises(adapter.Held):
                self.check()
            self.app_files['Info.plist'] = saved

    def test_malicious_zip_and_duplicate_json_fail(self):
        with self.assertRaisesRegex(adapter.Held, 'duplicate_json_key'):
            tf.json_bytes(b'{"key":1,"key":2}')
        path = Path(self.config['ipa']['path'])
        with zipfile.ZipFile(path, 'a') as stream:
            stream.writestr('../outside', b'bad')
        self.config['ipa'] = pin(path)
        with self.assertRaisesRegex(adapter.Held, 'unsafe_ipa_entry'):
            self.check()
        self.assertFalse((self.root / 'outside').exists())

    def test_main_failure_has_no_raw_values_or_traceback(self):
        self.config['externalTestersAllowed'] = True
        config_path = self.root / 'config.json'
        config_path.write_text(json.dumps(self.config))
        with patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(tf.main(['--config', str(config_path), '--scratch-root', str(self.root)]), 2)
        receipt = json.loads(output.getvalue())
        self.assertFalse(receipt['candidatePreflightPassed'])
        self.assertEqual(receipt['reason'], 'external_testers_forbidden')
        self.assertNotIn(str(self.root), output.getvalue())

    def test_missing_privacy_category_is_held_even_if_report_exits_zero(self):
        self.app_files['PrivacyInfo.xcprivacy'] = plistlib.dumps({'NSPrivacyAccessedAPITypes': []})
        self.write_ipa()
        with self.assertRaisesRegex(adapter.Held, 'privacy_required_reason_missing:FileTimestamp'):
            self.check()

    def test_privacy_category_without_reason_cannot_cover_api(self):
        self.privacy['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'] = []
        self.app_files['PrivacyInfo.xcprivacy'] = plistlib.dumps(self.privacy)
        self.write_ipa()
        with self.assertRaisesRegex(adapter.Held, 'privacy_nonempty_reasons_required'):
            self.check()

    def test_failed_native_analysis_never_counts_as_no_apis(self):
        original = self.native_boundary
        def fail_nm(args, **kw):
            if Path(str(args[0])).name == 'nm':
                return subprocess.CompletedProcess(args, 1, b'', b'not a binary')
            return original(args, **kw)
        with patch.object(subprocess, 'run', fail_nm), self.assertRaisesRegex(adapter.Held, 'command_failed:nm'):
            self.check()

    def test_native_signature_failure_does_not_trust_readback_boolean(self):
        original = self.native_boundary
        def fail_signature(args, **kw):
            if Path(str(args[0])).name == 'codesign' and '--verify' in args:
                return subprocess.CompletedProcess(args, 1, b'', b'invalid signature')
            return original(args, **kw)
        with patch.object(subprocess, 'run', fail_signature), self.assertRaisesRegex(adapter.Held, 'command_failed:codesign'):
            self.check()

    def test_native_warning_is_failure_despite_zero_exit(self):
        original = self.native_boundary
        def warning(args, **kw):
            result = original(args, **kw)
            if Path(str(args[0])).name == 'bash':
                result.stderr = b'PRIVACY_REQUIRED_REASON_WARNING\n'
            return result
        with patch.object(subprocess, 'run', warning), self.assertRaisesRegex(adapter.Held, 'privacy_warning'):
            self.check()

    def test_malformed_plist_returns_structured_failure(self):
        self.record('exportOptions', b'<?xml version="1.0"?><plist><dict>',
                    Path(self.config['exportOptions']['path']))
        config = self.root / 'broken-config.json'
        config.write_text(json.dumps(self.config))
        with patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(tf.main(['--config', str(config), '--scratch-root', str(self.root)]), 2)
        receipt = json.loads(output.getvalue())
        self.assertFalse(receipt['candidatePreflightPassed'])
        self.assertTrue(receipt['reason'].startswith('missing_or_invalid_input:'))


class ExistingLocalEvidenceTests(unittest.TestCase):
    @unittest.skipUnless((EVIDENCE / 'full-preservation-readback.json').is_file(), '기존 로컬 보존 자료 없음')
    def test_original55_archive_and_independent_restore_read_only(self):
        result = tf.preservation(local_preservation_config())
        self.assertEqual(result['files'], 55)
        self.assertTrue(result['independentRestoreRechecked'])
        self.assertFalse(result['newDevicePreservationVerified'])


if __name__ == '__main__':
    unittest.main()

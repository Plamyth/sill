import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('adapter', Path(__file__).with_name('adapter.py'))
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

class AdapterContract(unittest.TestCase):
    def test_lease_denials_never_call_device(self):
        with tempfile.TemporaryDirectory() as directory:
            lease_path = Path(directory) / 'lease.json'
            config = {'leaseFile': str(lease_path), 'deviceUDID': 'own-ipad'}
            grant = {'schema': 'ccr.device-lease/v1', 'owner': adapter.OWNER,
                     'deviceUDID': 'own-ipad', 'expiresAt': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5)).isoformat(),
                     'actions': ['install','launch','copy','test'], 'handoffEvidence': 'existing-owner-handoff'}
            for key, value in [('owner','foreign'),('deviceUDID','another'),('expiresAt','2020-01-01T00:00:00+00:00'),('actions',[]),('handoffEvidence','')]:
                invalid = dict(grant, **{key:value}); lease_path.write_text(json.dumps(invalid))
                with patch.object(adapter, 'command') as command:
                    with self.assertRaises(adapter.Held):
                        adapter.device(config, ['install','app','untrusted'], Path(directory)/'log')
                    command.assert_not_called()
            lease_path.write_text(json.dumps(grant)); adapter.lease(config)

    def test_dirty_or_wrong_ref_cannot_deploy(self):
        with patch.object(adapter, 'command', return_value=' M source.swift'):
            with self.assertRaisesRegex(adapter.Held, 'source_dirty'):
                adapter.identity({'repo':'.'})
        with patch.object(adapter, 'command', side_effect=['','main']):
            with self.assertRaisesRegex(adapter.Held, 'branch_mismatch'):
                adapter.identity({'repo':'.'})

    def test_fixture_is_independent_of_user_data(self):
        id = str(uuid.uuid4()); value = adapter.fixture(id)
        self.assertEqual(value['id'],id)
        self.assertEqual(value['strokes'],[])
        self.assertEqual(value['nodes'][0]['sourceStrokeIds'],[])
        self.assertEqual(value['nodes'][0]['id'],adapter.NODE)
        self.assertEqual(adapter.pixel()[:8],b'\x89PNG\r\n\x1a\n')

    def test_failed_copy_is_not_silently_absent(self):
        import subprocess
        with patch.object(adapter,'lease'), patch.object(adapter.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'',b'connection timeout')):
            with self.assertRaisesRegex(adapter.Held,'without_absence'):
                adapter.copy_file({'deviceUDID':'own-ipad'},Path('.'),'original','copy',optional=True)

    def test_reused_user_pid_cannot_be_terminated(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            adapter.write(work / 'deployment.json', {'testId':'fixture'})
            adapter.write(work / 'install.json', {'result':{'installedApplications':[
                {'bundleID':adapter.BUNDLE, 'installationURL':'file:///private/diagnostic/Sill.app/'}]}})
            def device(config, args, name):
                self.assertEqual(args[0:2],['info','processes'])
                adapter.write(args[-1], {'result':{'runningProcesses':[
                    {'processIdentifier':42,'executable':'file:///private/protected-user/Sill.app/Sill'}]}})
            with patch.object(adapter,'runtime_readback',return_value=({'processID':42,'bundleID':adapter.BUNDLE},Path('proof'))), patch.object(adapter,'device',side_effect=device):
                with self.assertRaisesRegex(adapter.Held,'owned_process_mismatch'):
                    adapter.stop_owned({},work)

    def test_coordinator_contract_is_reused_exactly(self):
        row = {'id':'bt-ccr-ipad','mode':'managed','test':{'requiredChecks':['native-canvas-ui'],
               'environment':'isolated-ipad-canvas','externalEffects':'zero',
               'deployCommand':['/usr/bin/python3','/한글/adapter.py','deploy'],
               'acceptanceCommand':['/usr/bin/python3','/한글/adapter.py','accept']}}
        def read(path):
            return {'projects':[row]} if str(path).endswith('projects.json') else {'requiredChecks':['native-canvas-ui']}
        expected = adapter.runpy.run_path('/Users/ambrion/.local/bin/bt-release-convergence')['acceptance_contract'](row)
        with patch.object(adapter,'read',side_effect=read):
            self.assertEqual(adapter.acceptance_contract({'repo':'.'}), expected)
        changed = dict(row, test=dict(row['test'],deployCommand=['/usr/bin/python3','different']))
        self.assertNotEqual(expected,adapter.runpy.run_path('/Users/ambrion/.local/bin/bt-release-convergence')['acceptance_contract'](changed))

    def test_release_failure_does_not_skip_device_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            work=Path(directory);vault=work/'isolated-vault';vault.mkdir()
            def command(args,*rest):
                if args[1]=='release':
                    raise adapter.Held('release failed')
                return ''
            def copy(config, root, source, destination, *rest, **kwargs):
                Path(destination).mkdir()
                return True
            with patch.object(adapter,'command',side_effect=command), patch.object(adapter,'stop_owned') as stop, patch.object(adapter,'lease'), patch.object(adapter,'copy_file',side_effect=copy), patch.object(adapter,'snapshots',return_value={'original':'same'}):
                self.assertFalse(adapter.cleanup({'deviceUDID':'own-ipad'},work,{'leaseId':'owned'},vault,'fixture',{'original':'same'}))
                stop.assert_called_once()
            result=adapter.read(work/'reset-readback.json')
            self.assertFalse(result['relayReleased'])
            self.assertTrue(result['deviceStateEmpty'])
            self.assertTrue(result['originalDataPreserved'])

    def test_collected_dead_relay_lease_can_restart_without_touching_live_orphan(self):
        with tempfile.TemporaryDirectory() as directory:
            work=Path(directory);repo=work/'repo';repo.mkdir()
            adapter.write(work/'context.json',{'token':'private-test-token','relayAddress':'http://192.168.1.1:8793'})
            prior={'leaseId':'old','owner':adapter.OWNER,'generation':'a'*40,'pid':42,'birth':'old-birth'}
            adapter.write(work/'relay-lease.json',prior)
            def command(args,*rest,**kwargs):
                if args[0]=='git':
                    return 'relay-commit' if args[1]=='rev-parse' else ''
                if 'start' in args:
                    return json.dumps(dict(prior,leaseId='new'))
                return ''
            policy={'LEASES':work/'authoritative','is_live':lambda row:False}
            config={'repo':str(repo),'relayRepo':str(repo),'relayCommit':'relay-commit','relayHost':'192.168.1.1','relayPort':8793,'nodeExecutable':'/node'}
            with patch.object(adapter,'command',side_effect=command),patch.object(adapter.runpy,'run_path',return_value=policy):
                _,_,service=adapter.relay_runtime(config,work,{'commit':'a'*40,'tree':'b'*40})
                self.assertEqual(service['leaseId'],'new')
                self.assertTrue(adapter.read(work/'relay-stale-reconciliation.json')['ownedProcessAbsent'])
            adapter.write(work/'relay-lease.json',prior)
            policy['is_live']=lambda row:True
            with patch.object(adapter,'command',side_effect=command),patch.object(adapter.runpy,'run_path',return_value=policy):
                with self.assertRaisesRegex(adapter.Held,'orphan_owned_relay_still_live'):
                    adapter.relay_runtime(config,work,{'commit':'a'*40,'tree':'b'*40})

    def test_device_option_precedes_application_argument_separator(self):
        with patch.object(adapter,'lease'),patch.object(adapter,'command',return_value='') as run:
            adapter.device({'deviceUDID':'own-ipad'},['process','launch',adapter.BUNDLE,'--','--ccr-test-runtime','fixture'],Path('log'))
            args=run.call_args.args[0]
            self.assertLess(args.index('--device'),args.index('--'))
            self.assertEqual(args[args.index('--device')+1],'own-ipad')
            self.assertEqual(args[-2:],['--ccr-test-runtime','fixture'])

    def test_build_cache_cannot_equal_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(adapter,'lease'),patch.object(adapter,'snapshots',return_value={}),patch.object(adapter,'command') as command:
                with self.assertRaisesRegex(adapter.Held,'build_cache_not_owned'):
                    adapter.deploy({'outputRoot':str(root),'buildCache':str(root)},root/'work',{'commit':'a'*40,'tree':'b'*40})
                command.assert_not_called()

if __name__ == '__main__':
    unittest.main()

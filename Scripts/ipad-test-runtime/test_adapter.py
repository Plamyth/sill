import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import struct
import sys
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

    def test_rotation_png_requires_decoded_canvas_and_following_link(self):
        import io, math
        from PIL import Image, ImageDraw
        self.assertFalse(adapter.valid_canvas_png(adapter.pixel()))
        self.assertFalse(adapter.valid_canvas_png(b'\x89PNG\r\n\x1a\n'+bytes(16)))
        scene = adapter.fixture(str(uuid.uuid4()))
        scene['nodes'][0]['rotationDegrees'] = 45
        scene['nodes'].append(dict(scene['nodes'][0],frame={'x':1050,'y':1000,'width':260,'height':120}))
        image = Image.new('RGB',(2048,1536),'black')
        def png():
            stream=io.BytesIO();image.save(stream,format='PNG');return stream.getvalue()
        self.assertFalse(adapter.valid_canvas_png(png(),scene))
        draw=ImageDraw.Draw(image)
        draw.line([(885,660),(1050,1060)],fill='cyan',width=4)
        self.assertFalse(adapter.valid_canvas_png(png(),scene))
        draw.line([(755+130/math.sqrt(2),660+130/math.sqrt(2)),(1050,1060)],fill='cyan',width=4)
        self.assertFalse(adapter.valid_canvas_png(png(),scene))
        points=[(755+(x-y)/math.sqrt(2),660+(x+y)/math.sqrt(2))
                for x,y in [(-130,-60),(130,-60),(130,60),(-130,60)]]
        draw.polygon(points,fill=(85,85,85))
        self.assertTrue(adapter.valid_canvas_png(png(),scene))
        self.assertFalse(adapter.valid_canvas_png(png()[:24],scene))

    def test_live_update_occurs_once_only_after_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory)/'live.log'
            calls = []
            script = "import time; print('CCR_ROTATION_LIVE_READY',flush=True); time.sleep(.3); print('CCR_ROTATION_LIVE_READY',flush=True); time.sleep(.3)"
            adapter.run_live_harness([sys.executable,'-c',script],log,lambda:calls.append(log.read_text()),3)
            self.assertEqual(len(calls),1)
            self.assertIn('CCR_ROTATION_LIVE_READY',calls[0])

    def test_live_update_without_readiness_or_after_failure_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            for script in ["print('not ready')", "import sys; print('CCR_ROTATION_LIVE_READY',flush=True); sys.exit(2)"]:
                with self.assertRaisesRegex(adapter.Held,'callback_failed'):
                    adapter.run_live_harness([sys.executable,'-c',script],Path(directory)/'live.log',lambda:None,3)
            with self.assertRaisesRegex(adapter.Held,'timeout'):
                adapter.run_live_harness([sys.executable,'-c','import time; time.sleep(5)'],Path(directory)/'timeout.log',lambda:None,.15)

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
            def inventory(config, args, log):
                adapter.write(args[-1], {'result':{'domainIdentifier':adapter.BUNDLE,'files':[]}})
            with patch.object(adapter,'command',side_effect=command), patch.object(adapter,'stop_owned') as stop, patch.object(adapter,'lease'), patch.object(adapter,'device',side_effect=inventory), patch.object(adapter,'snapshots',return_value={'original':'same'}):
                self.assertFalse(adapter.cleanup({'deviceUDID':'own-ipad'},work,{'leaseId':'owned'},vault,'fixture',{'original':'same'}))
                stop.assert_called_once()
            result=adapter.read(work/'reset-readback.json')
            self.assertFalse(result['relayReleased'])
            self.assertTrue(result['deviceStateEmpty'])
            self.assertTrue(result['originalDataPreserved'])

    def test_reset_requires_actual_inventory_even_when_copy_reports_failure(self):
        for remaining in [False, True]:
            with self.subTest(remaining=remaining), tempfile.TemporaryDirectory() as directory:
                work=Path(directory);vault=work/'isolated-vault';vault.mkdir()
                def command(args,*rest):
                    if args[0]=='xcrun': raise adapter.Held('command_failed:xcrun')
                    return json.dumps({'released':True})
                def inventory(config,args,log):
                    files=[{'relativePath':'Library/Application Support/CCRIntegrationTests/fixture/state/CanvasScene.json'}] if remaining else []
                    adapter.write(args[-1],{'result':{'domainIdentifier':adapter.BUNDLE,'files':files}})
                with patch.object(adapter,'command',side_effect=command),patch.object(adapter,'stop_owned'),patch.object(adapter,'lease'),patch.object(adapter,'device',side_effect=inventory),patch.object(adapter,'snapshots',return_value={}):
                    self.assertEqual(adapter.cleanup({'deviceUDID':'own-ipad'},work,{'leaseId':'owned'},vault,'fixture',{}),not remaining)
                self.assertEqual(adapter.read(work/'reset-readback.json')['deviceStateEmpty'],not remaining)

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

    def test_build_supplies_synthetic_owner_profile_before_codesign(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve()
            work = output / 'work'; work.mkdir()
            repo = Path(__file__).resolve().parents[2]
            config = {'repo':str(repo), 'outputRoot':str(output), 'developmentTeam':'ZPTXHJ866D'}
            def stop_after_build(args, *rest):
                self.assertEqual(args[0], 'xcodebuild')
                values = dict(str(arg).split('=',1) for arg in args if str(arg).startswith('CCR_OWNER_MAC_BOOTSTRAP_'))
                profile = Path(values['CCR_OWNER_MAC_BOOTSTRAP_PROFILE'])
                self.assertTrue(profile.is_relative_to(output))
                self.assertEqual(adapter.sha(profile.read_bytes()), values['CCR_OWNER_MAC_BOOTSTRAP_SHA256'])
                provision = adapter.runpy.run_path(str(repo / 'Scripts/provision-owner-bootstrap.py'))
                value = provision['validate'](profile.read_bytes())
                self.assertEqual(value['macID'], '0' * 16)
                self.assertEqual(value['remotePort'], 1)
                raise adapter.Held('stop_after_build_input_check')
            with patch.object(adapter,'lease'), patch.object(adapter,'snapshots',return_value={}), patch.object(adapter,'command',side_effect=stop_after_build), patch.object(adapter,'device') as device:
                with self.assertRaisesRegex(adapter.Held,'stop_after_build_input_check'):
                    adapter.deploy(config,work,{'commit':'a'*40,'tree':'b'*40})
                device.assert_not_called()

    def test_build_cache_cannot_equal_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(adapter,'lease'),patch.object(adapter,'snapshots',return_value={}),patch.object(adapter,'command') as command:
                with self.assertRaisesRegex(adapter.Held,'build_cache_not_owned'):
                    adapter.deploy({'outputRoot':str(root),'buildCache':str(root)},root/'work',{'commit':'a'*40,'tree':'b'*40})
                command.assert_not_called()

if __name__ == '__main__':
    unittest.main()

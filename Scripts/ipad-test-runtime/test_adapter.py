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

    def test_comment_readback_requires_one_stable_user_comment_and_preserves_original(self):
        baseline = adapter.comment_fixture(str(uuid.uuid4()))
        comment_id = str(uuid.uuid4())
        def saved():
            scene = json.loads(json.dumps(baseline))
            scene['revision'] += 1
            scene['annotations'].append({'id':comment_id,'nodeId':adapter.NODE,'text':'댓글 👩🏽‍💻','author':'사용자'})
            return scene
        self.assertEqual(adapter.verify_comment_scene(saved(),baseline,'댓글 👩🏽‍💻'),comment_id)
        self.assertEqual(adapter.verify_comment_scene(saved(),baseline,'댓글 👩🏽‍💻',comment_id),comment_id)
        mutations = [
            lambda s:s['nodes'][0].update(text='원문 손실'),
            lambda s:s['nodes'][0].update(id=str(uuid.uuid4())),
            lambda s:s['annotations'][0].update(text='AI 주석 손실'),
            lambda s:s['annotations'][-1].update(text='다른 댓글'),
            lambda s:s['annotations'][-1].update(nodeId=s['nodes'][1]['id']),
            lambda s:s['annotations'][-1].update(id='not-a-uuid'),
            lambda s:s['annotations'][-1].update(id=baseline['annotations'][0]['id']),
            lambda s:s['annotations'].append(dict(s['annotations'][-1])),
            lambda s:s.update(revision=baseline['revision']),
            lambda s:s.update(drawingBase64='원본 획 손실'),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                scene = saved(); mutate(scene)
                with self.assertRaises(adapter.Held):
                    adapter.verify_comment_scene(scene,baseline,'댓글 👩🏽‍💻')
        with self.assertRaisesRegex(adapter.Held,'comment_id_changed'):
            adapter.verify_comment_scene(saved(),baseline,'댓글 👩🏽‍💻',str(uuid.uuid4()))

    def test_comment_flow_restores_context_and_checks_each_ui_save_before_reopen(self):
        import base64
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            adapter.write(work/'context.json',{'test':'isolated'})
            scene = adapter.fixture(str(uuid.uuid4()))
            comment_id = str(uuid.uuid4())
            copies = []
            methods = []
            def request(server, method, path):
                return 200, {'revision':scene['revision'],'noteSha256':'test-sha',
                             'sceneJSONBase64':base64.b64encode(json.dumps(scene).encode()).decode()}
            def seed(server, value, image, base):
                nonlocal scene
                scene = json.loads(json.dumps(value))
                return 200, {}
            def copy(config, work, source, destination, direction='from', **kwargs):
                copies.append((str(source),str(destination),direction,kwargs))
                if direction == 'from': adapter.write(destination,scene)
            def harness(config, work, method, variables=None):
                methods.append(method)
                if method == 'testCommentSave':
                    scene['revision'] += 1
                    comments = [r for r in scene['annotations'] if r['author'] == '사용자']
                    if comments: comments[0]['text'] = variables['CCR_COMMENT_TEXT']
                    else: scene['annotations'].append({'id':comment_id,'nodeId':adapter.NODE,
                        'text':variables['CCR_COMMENT_TEXT'],'author':'사용자'})
                return work/(method+'.xcresult')
            with patch.object(adapter,'request',side_effect=request), patch.object(adapter,'save_scene',side_effect=seed), \
                 patch.object(adapter,'encode_scene',side_effect=lambda _,s:json.dumps(s).encode()), \
                 patch.object(adapter,'stop_owned'), patch.object(adapter,'copy_file',side_effect=copy), \
                 patch.object(adapter,'harness',side_effect=harness):
                proof = adapter.accept_comments({},work,{},scene['id'])
                self.assertEqual(proof['commentID'],comment_id)
                self.assertEqual(len(proof['edits']),2)
                self.assertEqual(methods,['testCommentSave','testCommentReopen','testCommentSave','testCommentReopen',
                    'testStaleCommentDraftRequiresExplicitDiscard','testCommentReopen','testRulerToggleAcrossDrawingAndSelection'])
                self.assertEqual(copies[0][2:],('to',{'replace':True}))
                self.assertTrue(copies[1][0].endswith('/context.json'))
                self.assertTrue(copies[1][1].endswith('/context.json'))
                self.assertEqual(copies[1][2],'to')
                self.assertTrue(adapter.read(work/'comment-functional-readback.json'))
                methods.clear()
                with patch.object(adapter,'harness',side_effect=lambda c,w,m,v=None:methods.append(m) or w/'unsaved.xcresult'):
                    with self.assertRaisesRegex(adapter.Held,'comment_text_or_target_mismatch'):
                        adapter.accept_comments({},work,{},scene['id'])
                self.assertEqual(methods,['testCommentSave'])

    def test_rotation_png_requires_decoded_canvas_and_following_link(self):
        import base64, math, subprocess, zlib
        with tempfile.TemporaryDirectory() as directory:
            encoder=Path(directory)/'encoder'
            repo=Path(__file__).resolve().parents[2]
            subprocess.run(['xcrun','swiftc','-parse-as-library',
                str(repo/'iOSClient/CanvasBridge/CanvasModel.swift'),
                str(Path(__file__).with_name('NativeSceneEncoder.swift')),'-o',str(encoder)],
                env=adapter.ENV,check=True,capture_output=True)
            scene=adapter.fixture(str(uuid.uuid4()));scene['nodes'][0]['rotationDegrees']=45
            scene['nodes'].append(dict(scene['nodes'][0],id=str(uuid.uuid4()),frame={'x':1050,'y':1000,'width':260,'height':120}))
            check=lambda data:adapter.valid_canvas_png(data,scene,encoder)
            self.assertFalse(check(adapter.pixel()))
            self.assertFalse(check(b'\x89PNG\r\n\x1a\n'+bytes(16)))
            width,height=2048,1536
            pixels=bytearray(width*height*3)
            def point(x,y,color):
                i=(round(y)*width+round(x))*3;pixels[i:i+3]=bytes(color)
            def line(a,b):
                for i in range(1500):
                    t=i/1499;x=round(a[0]+(b[0]-a[0])*t);y=round(a[1]+(b[1]-a[1])*t)
                    for dx in range(-2,3):
                        for dy in range(-2,3):point(x+dx,y+dy,(0,255,255))
            def png():
                def chunk(k,v):return struct.pack('>I',len(v))+k+v+struct.pack('>I',zlib.crc32(k+v))
                raw=b''.join(b'\x00'+pixels[y*width*3:(y+1)*width*3] for y in range(height))
                return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
            self.assertFalse(check(png()))
            line((885,660),(1050,1060));self.assertFalse(check(png()))
            line((755+130/math.sqrt(2),660+130/math.sqrt(2)),(1050,1060));self.assertFalse(check(png()))
            for y in range(510,810):
                for x in range(605,905):
                    a=(x-755+y-660)/math.sqrt(2);b=(y-660-(x-755))/math.sqrt(2)
                    if abs(a)<129 and abs(b)<59:point(x,y,(85,85,85))
            self.assertTrue(check(png()))
            self.assertFalse(check(png()[:24]))
            self.assertFalse(check(png()[:-12]))
            original=png()
            position=8
            while original[position+4:position+8] != b'IDAT':position+=12+struct.unpack('>I',original[position:position+4])[0]
            size=struct.unpack('>I',original[position:position+4])[0]
            compressed=original[position+8:position+8+size]
            suffix=original[position+12+size:]
            def changed_idat(body):
                return original[:position]+struct.pack('>I',len(body))+b'IDAT'+body+struct.pack('>I',zlib.crc32(b'IDAT'+body))+suffix
            bad_crc=bytearray(original);bad_crc[position+8+size]^=1
            self.assertFalse(check(bytes(bad_crc)))
            bad_adler=bytearray(compressed);bad_adler[-1]^=1
            for broken in [bytes(bad_adler),compressed[:-5],compressed[:-100],compressed+zlib.compress(b'extra')]:
                self.assertFalse(check(changed_idat(broken)))

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
            common_git = str(repo / '.git')
            def stop_after_build(args, *rest, **kwargs):
                if args[0] == 'git':
                    self.assertEqual(args, ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'])
                    self.assertEqual(kwargs, {'cwd': config['repo']})
                    return common_git
                self.assertEqual(args[0], 'xcodebuild')
                self.assertIn('CCR_SOURCE_GIT_COMMON_DIR=' + common_git, args)
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

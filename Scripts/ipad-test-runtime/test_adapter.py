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

class HarnessResultAcceptance(unittest.TestCase):
    def details(self, method):
        identity = 'CanvasBridgeUITests/' + method + '()'
        url = 'test://com.apple.xcode/CanvasBridge/CanvasBridgeUITests/' + identity[:-2]
        return {'testIdentifier':identity, 'testIdentifierURL':url, 'testResult':'Passed',
                'testRuns':[{'nodeType':'Device', 'result':'Passed', 'children':[
                    {'nodeType':'Test Plan Configuration', 'nodeIdentifierURL':url, 'result':'Passed'}]}]}

    def exercise(self, root, details, live=False, exists=True):
        import plistlib
        run = root / 'HarnessDerivedData/Build/Products/test.xctestrun'
        run.parent.mkdir(parents=True)
        run.write_bytes(plistlib.dumps({'CanvasBridgeUITests':{'EnvironmentVariables':{}}}))
        adapter.write(root/'deployment.json',{'testId':'isolated'})
        def command(args, *unused):
            if args[0] == 'xcodebuild':
                if exists: Path(args[args.index('-resultBundlePath')+1]).mkdir()
                return 'Executed 0 tests, with 0 failures; TEST SUCCEEDED'
            self.assertEqual(args[:5],['xcrun','xcresulttool','get','test-results','test-details'])
            self.assertEqual(args[-2:],['--test-id','CanvasBridgeUITests/testReviewReopen()'])
            return json.dumps(details)
        def run_live(args, log, on_ready, **kwargs):
            command(args); on_ready()
        calls = []
        with patch.object(adapter,'lease'), patch.object(adapter,'command',side_effect=command) as cmd, \
             patch.object(adapter,'run_live_harness',side_effect=run_live):
            result = adapter.harness({'deviceUDID':'unexecuted'},root,'testReviewReopen',
                                     on_ready=(lambda:calls.append(True)) if live else None)
            self.assertEqual(sum(call.args[0][0] == 'xcrun' for call in cmd.call_args_list),1)
        self.assertEqual(calls,[True] if live else [])
        return result

    def test_harness_requires_existing_bundle_for_both_command_paths(self):
        for live in [False,True]:
            with self.subTest(live=live), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(adapter.Held,'xcresult_missing'):
                    self.exercise(Path(directory),self.details('testReviewReopen'),live,exists=False)

    def test_harness_requires_requested_method_and_one_passed_execution(self):
        for failure in ['no_tests','wrong_method','wrong_bundle','skipped','failed','duplicate_device',
                        'duplicate_configuration','no_configuration','failed_execution','repetition','malformed']:
            for live in [False,True]:
                with self.subTest(failure=failure,live=live), tempfile.TemporaryDirectory() as directory:
                    details = self.details('other' if failure == 'wrong_method' else 'testReviewReopen')
                    run = details['testRuns'][0]; configuration = run['children'][0]
                    if failure == 'wrong_bundle': details['testIdentifierURL'] = 'test://other/CanvasBridgeUITests/testReviewReopen'
                    if failure in ['skipped','failed']: details['testResult'] = failure.title()
                    if failure == 'no_tests': details['testRuns'] = []
                    if failure == 'duplicate_device': details['testRuns'].append(run.copy())
                    if failure == 'duplicate_configuration': run['children'].append(configuration.copy())
                    if failure == 'no_configuration': run['children'] = []
                    if failure == 'failed_execution': configuration['result'] = 'Failed'
                    if failure == 'repetition': configuration['children'] = [{'result':'Passed'},{'result':'Passed'}]
                    if failure == 'malformed': details = []
                    with self.assertRaises(adapter.Held): self.exercise(Path(directory),details,live)

    def test_harness_accepts_single_matching_execution_once(self):
        for live in [False,True]:
            with self.subTest(live=live), tempfile.TemporaryDirectory() as directory:
                self.assertTrue(self.exercise(Path(directory),self.details('testReviewReopen'),live).is_dir())

class ReviewJournalAcceptance(unittest.TestCase):
    def test_only_absent_payload_can_be_cleared(self):
        import base64
        envelopes = [{'schemaVersion':1,'sha256':adapter.sha(b'')}]
        for raw in [b'',b'null',b'[]',b'1',b'"text"']:
            envelopes.append({'schemaVersion':1,'sha256':adapter.sha(raw),
                              'payload':base64.b64encode(raw).decode()})
        for payload in [None,False,1,[],{},'%%%']:
            envelopes.append({'schemaVersion':1,'sha256':adapter.sha(b''),'payload':payload})
        for index,envelope in enumerate(envelopes):
            with self.subTest(envelope=envelope), tempfile.TemporaryDirectory() as directory:
                with patch.object(adapter,'copy_file'), patch.object(adapter,'read',return_value=envelope):
                    if index == 0: adapter.review_journal({},Path(directory),'id','cleared')
                    else:
                        with self.assertRaises((adapter.Held,ValueError)):
                            adapter.review_journal({},Path(directory),'id','cleared')

    def test_draft_object_schema_and_field_types_are_strict(self):
        import base64
        expected = {'relayAddress':'http://127.0.0.1:8793','base':{'text':'base'},'draft':'draft'}
        valid = dict(expected,schemaVersion=1,sceneID='12345678-1234-4234-8234-123456789abc')
        for field,value in [('schemaVersion',True),('draft',None),('base',[]),('submittedText',3),('nodeID',3)]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                raw = json.dumps(dict(valid,**{field:value})).encode()
                envelope = {'schemaVersion':1,'sha256':adapter.sha(raw),'payload':base64.b64encode(raw).decode()}
                with patch.object(adapter,'copy_file'), patch.object(adapter,'read',return_value=envelope):
                    with self.assertRaises(adapter.Held):
                        adapter.review_journal({},Path(directory),valid['sceneID'],'draft',expected)

class ReviewAcceptance(unittest.TestCase):
    def exercise(self, directory, failure=None):
        work = Path(directory); vault = work / 'isolated-vault'; vault.mkdir()
        test_id = '12345678-1234-4234-8234-123456789abc'
        methods = []; saved = {}
        def record(path, status, body):
            row = {'path':path,'status':status,'baseSha256':body['baseSha256'],
                   'textSha256':adapter.sha(body['text'].encode())}
            with (work / 'review-note-writes.jsonl').open('a') as output:
                output.write(json.dumps(row)+'\n')
        def request(server, method, endpoint, body=None, authenticated=True):
            import urllib.parse
            path = urllib.parse.parse_qs(urllib.parse.urlsplit(endpoint).query)['path'][0]
            file = vault / path
            if not authenticated:
                if method == 'PUT': record(path,401,body)
                return (200 if failure == 'unauth_not_rejected' else 401), {'error':'Unauthorized'}
            if method == 'PUT':
                current = adapter.sha(file.read_bytes()) if file.exists() else None
                if current != body['baseSha256']:
                    record(path,409,body)
                    return (200 if failure == 'stale_not_rejected' else 409), {'error':'stale'}
                file.write_bytes(body['text'].encode())
                record(path,200,body)
            if not file.exists():
                return (200 if failure == 'missing_not_rejected' and saved.get('rated') else 404), {'error':'missing'}
            if failure == 'server_readback_absent' and saved.get('saved'):
                return 503, {'error':'missing result'}
            text = file.read_bytes().decode()
            return 200, {'path':path, 'text':text, 'sha256':adapter.sha(file.read_bytes()), 'modifiedAt':'fixture'}
        def journal(destination, payload):
            import base64
            raw = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else b''
            adapter.write(destination, {'schemaVersion':1, 'sha256':adapter.sha(raw),
                **({'payload':base64.b64encode(raw).decode()} if payload is not None else {})})
        def copy(config, target, source, destination, **kwargs):
            if source.endswith('CanvasScene.json'):
                adapter.write(destination, {'id':test_id, 'revision':8 if failure == 'scene' and saved.get('rated') else 7,
                                            'nodes':[{'text':'unrelated'}]})
            else:
                payload = saved.get('pending')
                journal(destination, payload)
                if failure == 'journal_hash' and payload:
                    envelope = adapter.read(destination); envelope['sha256'] = '0'*64
                    adapter.write(destination,envelope)
        def harness(config, target, method, variables=None, on_ready=None, **kwargs):
            methods.append(method)
            v = variables or {}; path = v['CCR_REVIEW_NOTE']; file = vault / path
            if method == 'testReviewEditDraftPreserved':
                base = request({},'GET','/vault/note?path='+path)[1]
                saved['pending'] = {'schemaVersion':1, 'sceneID':test_id,
                    'relayAddress':'http://127.0.0.1:8793', 'base':base, 'draft':v['CCR_REVIEW_DRAFT']}
            elif method == 'testReviewSaveDraft':
                if failure != 'ui_did_not_save': file.write_bytes(v['CCR_REVIEW_DRAFT'].encode())
                saved['saved'] = True
                if failure != 'journal_not_cleared': saved['pending'] = None
            elif method == 'testReviewGood':
                if failure != 'ui_did_not_rate':
                    import re
                    text = file.read_bytes().decode(); header = re.search(r'<!-- ccr-review-card:v1 (.*?) -->',text)
                    metadata = json.loads(header[1])
                    metadata.update(eventID='44444444-4444-4444-8444-444444444444', ratedAt=1800000000,
                                    dueAt=1800086400 if failure != 'wrong_due' else 1800086401)
                    if failure == 'card_id': metadata['cardID']='55555555-5555-4555-8555-555555555555'
                    if failure == 'event_id': metadata['eventID']='invalid'
                    if failure == 'event_id_reused': metadata['eventID']='22222222-2222-4222-8222-222222222222'
                    text = text[:header.start(1)] + json.dumps(metadata,sort_keys=True,separators=(',',':')) + text[header.end(1):]
                    if failure == 'outside': text += 'unrequested'
                    body = {'baseSha256':adapter.sha(file.read_bytes()),'text':text}
                    request({},'PUT','/vault/note?path='+path,body)
                    if failure == 'duplicate_grade_request': record(path,200,body)
            if on_ready: on_ready()
            if method == 'testReviewReopen' and failure == 'duplicate_rating' and 'rated' in saved:
                file.write_bytes(file.read_bytes().replace(b'1800000000',b'1800000001').replace(b'1800086400',b'1800086401'))
            if method == 'testReviewGood': saved['rated']=True
            if failure == 'other_note':
                for other in vault.glob('*.md'):
                    if other != file: other.write_bytes(b'damaged')
            result = work / (method + '-' + str(len(methods)) + '.xcresult')
            if failure != 'ui_result_absent': result.mkdir()
            if failure == 'ui_result_removed' and method == 'testReviewReopen' and saved.get('rated'):
                for previous in work.glob('*.xcresult'):
                    if previous != result: previous.rmdir()
            return result
        with patch.object(adapter,'request',side_effect=request), patch.object(adapter,'copy_file',side_effect=copy), \
             patch.object(adapter,'harness',side_effect=harness), patch.object(adapter.time,'time',return_value=1800000000):
            result = adapter.accept_review({},work,{'address':'http://127.0.0.1:8793'},vault,test_id)
        return result, methods

    def test_review_ui_to_note_and_journal_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            proof, methods = self.exercise(directory)
            self.assertEqual(proof['metadata']['dueAt']-proof['metadata']['ratedAt'],86400)
            self.assertEqual(proof['metadata']['eventID'],'44444444-4444-4444-8444-444444444444')
            self.assertIn('testReviewEditDraftPreserved',methods)
            self.assertIn('testReviewLiveRemoteRevision',methods)
            self.assertIn('testReviewStaleSessionRejected',methods)
            self.assertIn('testReviewMissingSourceRejected',methods)
            self.assertTrue(proof['otherNotePreserved'])
            self.assertTrue(proof['scenePreserved'])
            self.assertTrue(proof['singleRatingEffect'])

    def test_review_cannot_accept_ui_only_or_corrupt_results(self):
        for failure in ['ui_did_not_save','ui_did_not_rate','wrong_due','card_id','event_id',
                        'outside','other_note','journal_hash','duplicate_rating','duplicate_grade_request',
                        'server_readback_absent','stale_not_rejected','unauth_not_rejected','missing_not_rejected',
                        'journal_not_cleared','scene','event_id_reused','ui_result_absent','ui_result_removed']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises((adapter.Held,ValueError)):
                    self.exercise(directory,failure)

    def test_review_wire_audit_observes_existing_endpoint_without_changing_response(self):
        import subprocess
        script = r'''
const assert = require('node:assert/strict'), vm = require('node:vm');
const {EventEmitter} = require('node:events');
const source = require('node:fs').readFileSync(0,'utf8');
const server = new EventEmitter(); server.listen = () => {};
const audit = [], config = {relayRepo:'/relay',noteAudit:'/owned/audit'};
const files = {readFileSync:() => JSON.stringify(config),appendFileSync:(path,text) => {
  assert.equal(path,'/owned/audit'); audit.push(JSON.parse(text));
}};
vm.runInNewContext(source,{process:{argv:['node','relay.js','config']},URL,Buffer,
  require:name => name === 'node:fs' ? files : name === '/relay/relay/server.js'
    ? {createServer:() => server} : require(name)});
function request(method,url,status,body) {
  const req = new EventEmitter(), res = new EventEmitter();
  req.method=method; req.url=url; res.statusCode=status;
  server.emit('request',req,res);
  const bytes = Buffer.from(JSON.stringify(body));
  req.emit('data',bytes.subarray(0,3)); req.emit('data',bytes.subarray(3));
  req.emit('end'); res.emit('finish'); assert.equal(res.statusCode,status);
}
request('GET','/vault/note?path=untouched.md',200,{});
request('PUT','/vault/canvas?id=unrelated',200,{});
assert.equal(audit.length,0);
const text='한글 👩🏽‍💻 e\u0301';
for (const status of [200,409,401,503])
  request('PUT','/vault/note?path=%ED%95%9C%EA%B8%80.md',status,{baseSha256:'a'.repeat(64),text});
assert.deepEqual(audit.map(row=>row.status),[200,409,401,503]);
for (const row of audit) {
  assert.equal(row.path,'한글.md');
  assert.equal(row.textSha256,require('node:crypto').createHash('sha256').update(text).digest('hex'));
  assert.equal(row.baseSha256,'a'.repeat(64));
  assert.deepEqual(Object.keys(row).sort(),['baseSha256','path','status','textSha256']);
}
console.log('note audit: four actual response statuses, no response mutation, no raw text/token');
'''
        result = subprocess.run(['node','-e',script],input=Path(__file__).with_name('relay.js').read_text(),
                                text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_review_callback_uses_its_own_readiness_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            adapter.run_live_harness([sys.executable,'-c',
                "import time; print('CCR_ROTATION_LIVE_READY',flush=True); time.sleep(.2); "
                "print('CCR_REVIEW_LIVE_READY',flush=True); time.sleep(.3)"],Path(directory)/'live.log',
                lambda:calls.append(True),3,ready_marker='CCR_REVIEW_LIVE_READY')
            self.assertEqual(calls,[True])

if __name__ == '__main__':
    unittest.main()

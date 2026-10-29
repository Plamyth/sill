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

def existing_runner_fixture(work, run):
    receipt = work/'existing-runner.json'
    adapter.write(receipt,{'schema':'ccr.existing-xctest-runner/v1','installed':True,'team':adapter.NORMAL_TEAM,
        'bundleIdentifier':'com.ambrion.rea.appaudit.UITests.xctrunner',
        'testBundleRelativePath':'__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest'})
    return {'deviceUDID':'offline','existingXctestrun':str(run),'existingXctestrunSHA256':adapter.sha(run.read_bytes()),
        'existingRunnerReceipt':str(receipt),'existingRunnerReceiptSHA256':adapter.sha(receipt.read_bytes())}

class PDFRecoveryProtectionContract(unittest.TestCase):
    def test_complete_document_cache_and_pending_intent_are_protected(self):
        name='CanvasDocumentSource.json'
        self.assertIn(name,adapter.ORIGINALS)
        with tempfile.TemporaryDirectory() as temporary:
            work=Path(temporary)
            content=None
            def copy(config,work,source,target,**kwargs):
                if source=='Library/Application Support/'+name and content is not None:
                    self.assertEqual(kwargs['bundle'],adapter.USER_BUNDLE)
                    target.write_bytes(content)
                    return True
                return False
            def device(config,args,log):
                adapter.write(Path(args[-1]),{'result':{'unchanged':True}})
            with patch.object(adapter,'device',side_effect=device),patch.object(adapter,'copy_file',side_effect=copy):
                absent=adapter.snapshots({},work,'absent')
                self.assertIsNone(absent[name])
                content=b'{"document":{"pages":["entire original"]},"sync":{"phase":"sending"}}'
                before=adapter.snapshots({},work,'before-document')
                self.assertEqual(before[name],adapter.sha(content))
                self.assertFalse(adapter.same_user_data(absent,before))
                self.assertTrue(adapter.same_user_data(before,adapter.snapshots({},work,'same-document')))
                content=content.replace(b'sending',b'held')
                self.assertFalse(adapter.same_user_data(before,adapter.snapshots({},work,'changed-intent')))
                content=None
                self.assertFalse(adapter.same_user_data(before,adapter.snapshots({},work,'removed-document')))

    def test_pdf_journal_changes_are_in_normal_snapshot(self):
        self.assertIn('CanvasPDFExcerptCreate/recovery.json',adapter.ORIGINALS)
        self.assertIn('CanvasConflictRecovery',adapter.ORIGINALS)
        self.assertIn('CanvasLegacyScene.json',adapter.ORIGINALS)
        self.assertIn('CanvasWorkspace/bookmark.json',adapter.ORIGINALS)
        with tempfile.TemporaryDirectory() as temporary:
            work=Path(temporary)
            content=b'normal PDF create journal'
            def copy(config,work,source,target,**kwargs):
                if source.endswith('CanvasPDFExcerptCreate/recovery.json'):
                    target.write_bytes(content)
                    return True
                return False
            def device(config,args,name):
                adapter.write(Path(args[-1]),{'result':{'unchanged':True}})
            with patch.object(adapter,'device',side_effect=device),patch.object(adapter,'copy_file',side_effect=copy):
                before=adapter.snapshots({},work,'before')
                self.assertEqual(before['CanvasPDFExcerptCreate/recovery.json'],adapter.sha(content))
                self.assertTrue(adapter.same_user_data(before,adapter.snapshots({},work,'after')))
                content=b'changed PDF create journal'
                self.assertFalse(adapter.same_user_data(before,adapter.snapshots({},work,'changed')))

class PreparedInstallContract(unittest.TestCase):
    def fixture(self, directory):
        import plistlib, shutil, types
        root=Path(directory).resolve();work=root/'work';work.mkdir()
        app=root/'Sill.app';app.mkdir();(app/'_CodeSignature').mkdir()
        source={'commit':'a'*40,'tree':'b'*40}
        profile=Path('/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/owner-mac-bootstrap-20261022/public-profile-from-ipad-saved.json').read_bytes()
        (root/'public.json').write_bytes(profile)
        info={'CFBundleIdentifier':adapter.USER_BUNDLE,'CFBundleVersion':'71','CFBundleExecutable':'Sill',
              'CCRSourceCommit':source['commit'],'CCRSourceTree':source['tree'],'CCRSourceIdentityVerified':True}
        (app/'Info.plist').write_bytes(plistlib.dumps(info));(app/'Sill').write_bytes(b'parent signed Debug binary fixture')
        (app/'CCR-OwnerMacBootstrap.json').write_bytes(profile);(app/'_CodeSignature/CodeResources').write_bytes(b'signed fixture')
        (app/'embedded.mobileprovision').write_bytes(b'parent signed provisioning fixture')
        ent={'application-identifier':adapter.NORMAL_TEAM+'.'+adapter.USER_BUNDLE,
             'com.apple.developer.team-identifier':adapter.NORMAL_TEAM,'get-task-allow':True}
        metadata={'bundleIdentifier':adapter.USER_BUNDLE,'bundleVersion':'70','containerAccessible':True,'url':'file:///installed/Sill.app'}
        prior_app=root/'Prior/Sill.app';prior_app.parent.mkdir();shutil.copytree(app,prior_app)
        prior_info=dict(info,CFBundleVersion='70')
        (prior_app/'Info.plist').write_bytes(plistlib.dumps(prior_info))
        prior_ent=dict(ent)
        adapter.write(root/'signing.json',dict(prior_info,executableSHA256=adapter.sha((prior_app/'Sill').read_bytes()),
            bootstrapSHA256=adapter.APPROVED_OWNER_PROFILE_SHA256,entitlements=prior_ent,signatureValid=True))
        adapter.write(root/'install.json',{'info':{'outcome':'success','arguments':['devicectl','device','install','app',
            '--device','leased-ipad',str(prior_app),'--json-output','historical.json']},
            'result':{'installedApplications':[{'bundleID':adapter.USER_BUNDLE,'installationURL':metadata['url']}]}})
        adapter.write(root/'metadata.json',{'result':{'apps':[dict(metadata)],'deviceIdentifier':'leased-ipad'}})
        prior={'schema':'ccr.known-installed-artifact/v1','artifact':str(prior_app),
            'artifactManifestSHA256':adapter.digest_value(adapter.artifact_files(prior_app))}
        for label,key in [('signing','signingReadback'),('install','installRecord'),('metadata','metadata')]:
            prior[key+'Path']=str(root/(label+'.json'));prior[key+'SHA256']=adapter.sha((root/(label+'.json')).read_bytes())
        adapter.write(root/'installed.json',prior)
        context={'schema':'ccr.ipad-test-context/v1','id':str(uuid.uuid4()),**source,
                 'relayAddress':'http://192.168.1.2:8793','token':'parent-test-context-reference-123456789'}
        adapter.write(root/'context.json',context)
        adapter.write(root/'lease.json',{'schema':'ccr.device-lease/v1','owner':adapter.OWNER,'deviceUDID':'leased-ipad',
            'expiresAt':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=10)).isoformat(),
            'actions':['install','launch','copy','test'],'handoffEvidence':'parent-shared-stage'})
        config={'repo':str(root),'deviceUDID':'leased-ipad','developmentTeam':adapter.NORMAL_TEAM,'leaseFile':str(root/'lease.json'),
            'preparedArtifact':str(app),'preparedArtifactReceipt':str(root/'artifact.json'),
            'installedIdentityReceipt':str(root/'installed.json'),'installedIdentityReceiptSHA256':adapter.sha((root/'installed.json').read_bytes()),
            'preparedContext':str(root/'context.json'),'preparedContextSHA256':adapter.sha((root/'context.json').read_bytes()),
            'ownerBootstrapProfile':str(root/'public.json'),'ownerBootstrapSHA256':adapter.APPROVED_OWNER_PROFILE_SHA256}
        receipt={'schema':'ccr.signed-ipad-artifact/v1',**source,'bundleIdentifier':adapter.USER_BUNDLE,'team':adapter.NORMAL_TEAM,
            'build':'71','configuration':'Debug','ownerBootstrapSHA256':adapter.APPROVED_OWNER_PROFILE_SHA256,
            'buildSettings':{'CONFIGURATION':'Debug','SWIFT_ACTIVE_COMPILATION_CONDITIONS':['DEBUG'],
                'PRODUCT_BUNDLE_IDENTIFIER':adapter.USER_BUNDLE,'DEVELOPMENT_TEAM':adapter.NORMAL_TEAM,'CURRENT_PROJECT_VERSION':'71'}}
        data=root/'device-data';data.mkdir()
        for relative in ['Library/Application Support/'+name for name in adapter.ORIGINALS if name != 'CanvasConflictRecovery']+['Documents/nested/drawing','Library/Preferences/normal.plist']:
            path=data/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'unchanged normal user bytes')
        recovery=data/'Library/Application Support/CanvasConflictRecovery';recovery.mkdir()
        (recovery/'CanvasConflictChoice.json').write_bytes(b'unchanged unique conflict choice')
        (recovery/('CanvasConflictLocal-'+str(uuid.uuid4())+'.json')).write_bytes(b'unique local recovery')
        state=types.SimpleNamespace(root=root,work=work,app=app,source=source,config=config,info=info,receipt=receipt,
            ent=ent,priorEnt=prior_ent,priorApp=prior_app,metadata=metadata,context=context,data=data,commands=[],installCount=0,launchCount=0,mode=None,infoCount=0)
        def seal():
            state.receipt.update(files=adapter.artifact_files(app),entitlementsSHA256=adapter.sha(plistlib.dumps(state.ent,sort_keys=True)))
            state.receipt['manifestSHA256']=adapter.digest_value(state.receipt['files'])
            adapter.write(root/'artifact.json',state.receipt)
            config['preparedArtifactReceiptSHA256']=adapter.sha((root/'artifact.json').read_bytes())
        state.seal=seal;seal()
        def command(args,log=None,*unused,**kwargs):
            args=list(map(str,args));state.commands.append(args)
            if args[0]=='codesign':
                if state.mode=='bad-signature': raise adapter.Held('command_failed:codesign')
                if '--verbose=4' in args:
                    Path(log).write_text('Identifier='+adapter.USER_BUNDLE+'\nTeamIdentifier='+adapter.NORMAL_TEAM+'\n')
                if '--test-requirement' in args:self.assertTrue(args[args.index('--test-requirement')+1].startswith('=anchor'))
                if '--entitlements' in args:return plistlib.dumps(state.priorEnt if Path(args[-1])==prior_app else state.ent).decode()
                return ''
            if args[0]=='security':
                expiry=dt.datetime.now()+dt.timedelta(days=1)
                if state.mode=='expired-provision':expiry=dt.datetime(2020,1,1)
                return plistlib.dumps({'TeamIdentifier':[adapter.NORMAL_TEAM],'ExpirationDate':expiry,
                    'ProvisionedDevices':['leased-ipad'],'Entitlements':dict(state.ent)}).decode()
            if args[0]=='git':
                if args[1]=='status':return ''
                if args[1]=='branch':return 'integration/ccr-ipad'
                if state.mode=='repo-source':return 'f'*40
                return source['tree'] if args[-1]=='HEAD^{tree}' else source['commit']
            self.assertEqual(args[:3],['xcrun','devicectl','device'])
            if args[3:5]==['info','apps']:
                state.infoCount+=1
                if state.infoCount==2 and state.mode=='input-mutation':(app/'Sill').write_bytes(b'changed during verification')
                if state.infoCount==2 and state.mode=='before-data-change':(data/'Library/Preferences/normal.plist').write_bytes(b'external normal input changed')
                if state.infoCount==4 and state.mode=='isolated-metadata-change':state.metadata['bundleVersion']='99'
                if state.infoCount==4 and state.mode=='isolated-data-change':(data/'Library/Preferences/normal.plist').write_bytes(b'normal state changed after launch')
                adapter.write(args[args.index('--json-output')+1],{'result':{'apps':[dict(state.metadata)],'deviceIdentifier':'leased-ipad'}})
            elif args[3:5]==['info','processes']:
                adapter.write(args[args.index('--json-output')+1],{'result':{'runningProcesses':[
                    {'processIdentifier':123,'executable':'file:///installed/Sill.app/Sill' if state.mode!='wrong-process' else 'file:///different/app/Sill'}]}})
            elif args[3:5]==['install','app']:
                self.assertIn('--device',args);self.assertNotIn('-allowProvisioningUpdates',args)
                state.installCount+=1
                if state.mode=='install-unknown':raise adapter.Held('command_failed:devicectl')
                state.metadata['bundleVersion']='71'
                if state.mode=='data-mutation':(data/'Library/Preferences/normal.plist').write_bytes(b'user data changed')
                if state.mode=='receipt-mutation':(root/'context.json').write_bytes(b'changed parent context')
            elif args[3:5]==['process','launch']:
                state.launchCount+=1
                adapter.write(args[args.index('--json-output')+1],{'result':{'processIdentifier':123}})
                self.assertIn(adapter.USER_BUNDLE,args);self.assertEqual(args[-3:],['--','--ccr-test-runtime',context['id']])
                runtime={'schema':'ccr.ipad-test-runtime/v1','id':context['id'],**source,'bundleID':adapter.USER_BUNDLE,
                    'build':'71','relayAddress':context['relayAddress'],'processID':123,
                    'storageRoot':'/private/normal-data/Library/Application Support/CCRIntegrationTests/'+context['id']+'/state',
                    'executableSHA256':adapter.sha((app/'Sill').read_bytes())}
                runtime['codeImages']={'Sill':adapter.sha((app/'Sill').read_bytes())}
                if (app/'Sill.debug.dylib').exists():runtime['codeImages']['Sill.debug.dylib']=adapter.sha((app/'Sill.debug.dylib').read_bytes())
                runtime['loadedCodeImagePaths']={name:'/installed/Sill.app/'+name for name in runtime['codeImages']}
                runtime['codeImageUUIDs']={name:'0'*32 for name in runtime['codeImages']}
                if state.mode=='runtime-source':runtime['commit']='f'*40
                adapter.write(data/('Library/Application Support/CCRIntegrationTests/'+context['id']+'/state/runtime.json'),runtime)
            else:self.fail('unexpected command boundary')
            return ''
        def copy(args,**kwargs):
            args=list(map(str,args));self.assertIn(adapter.USER_BUNDLE,args)
            direction=args[4];source_path=args[args.index('--source')+1];target=Path(args[args.index('--destination')+1])
            if direction=='from':source_path=data/source_path
            else:
                self.assertTrue(str(target).startswith('Library/Application Support/CCRIntegrationTests/'+context['id']+'/'))
                target=data/target;source_path=Path(source_path)
            source_path=Path(source_path)
            if not source_path.exists():return types.SimpleNamespace(returncode=1,stdout=b'No such file',stderr=b'')
            target.parent.mkdir(parents=True,exist_ok=True)
            if source_path.is_dir():shutil.copytree(source_path,target)
            else:shutil.copyfile(source_path,target)
            return types.SimpleNamespace(returncode=0,stdout=b'',stderr=b'')
        state.command=command;state.copy=copy
        return state

    def invoke(self, state):
        with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter.subprocess,'run',side_effect=state.copy),patch.object(adapter.time,'sleep'):
            return adapter.deploy_prepared(state.config,state.work,state.source)

    def test_complete_prepared_fixture_reaches_same_bundle_install_and_only_isolated_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            state=self.fixture(directory);result=self.invoke(state)
            self.assertEqual((state.installCount,state.launchCount),(1,1))
            self.assertTrue(result['sourceReadbackVerified']);self.assertTrue(result['normalReturnRequired'])
            self.assertFalse(result['functionalAcceptance']);self.assertEqual(result['bundleIdentifier'],adapter.USER_BUNDLE)
            self.assertNotIn('xcodebuild',[row[0] for row in state.commands])
            self.assertEqual(adapter.read(state.work/'prepared-install-attempt.json')['status'],'isolated-runtime-verified')
            with self.assertRaisesRegex(adapter.Held,'already_attempted'):self.invoke(state)
            self.assertEqual(state.installCount,1)

    def test_cli_dispatch_reaches_prepared_install_with_all_parent_inputs(self):
        import io, contextlib
        with tempfile.TemporaryDirectory() as directory:
            state=self.fixture(directory)
            state.config.update(outputRoot=str(state.root/'output'),relayHost='192.168.1.2',relayPort=8793)
            config_path=state.root/'config.json';adapter.write(config_path,state.config)
            original=state.command
            def command(args,*rest,**kwargs):
                if str(args[0]).endswith('/storage-route'):return json.dumps({'path':str(state.root)})
                if str(args[0]).endswith('/codex-source-guard'):return json.dumps({'repository':'github.com/plamyth/sill',**state.source})
                return original(args,*rest,**kwargs)
            output=io.StringIO()
            with patch.object(sys,'argv',['adapter.py','deploy-prepared','--config',str(config_path)]), \
                 patch.object(adapter,'command',side_effect=command),patch.object(adapter.subprocess,'run',side_effect=state.copy), \
                 patch.object(adapter.time,'sleep'),contextlib.redirect_stdout(output):
                code=adapter.main()
            self.assertEqual(code,0,output.getvalue())
            self.assertEqual(json.loads(output.getvalue())['status'],'applied')
            self.assertEqual((state.installCount,state.launchCount),(1,1))

    def test_missing_or_invalid_preconditions_never_install(self):
        for failure in ['missing','expired','old-build','wrong-team','source','not-debug','profile','signature','keychain','receipt','input-mutation','expired-provision','repo-source','before-data-change','synthetic-profile']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=self.fixture(directory)
                if failure=='missing':state.config.pop('preparedArtifactReceiptSHA256')
                elif failure=='expired':
                    value=adapter.read(state.root/'lease.json');value['expiresAt']='2020-01-01T00:00:00+00:00';adapter.write(state.root/'lease.json',value)
                elif failure=='old-build':
                    state.info['CFBundleVersion']='70';(state.app/'Info.plist').write_bytes(adapter.plistlib.dumps(state.info))
                    state.receipt['build']='70';state.receipt['buildSettings']['CURRENT_PROJECT_VERSION']='70';state.seal()
                elif failure=='wrong-team':state.config['developmentTeam']='another'
                elif failure=='source':state.receipt['commit']='f'*40;state.seal()
                elif failure=='not-debug':state.receipt['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=[];state.seal()
                elif failure=='profile':state.config['ownerBootstrapSHA256']='0'*64
                elif failure=='synthetic-profile':
                    fake=json.dumps({'schema':'ccr.owner-mac-bootstrap/v1','macID':'0'*16,
                        'fingerprint':adapter.base64.urlsafe_b64encode(bytes(32)).decode().rstrip('='),
                        'addresses':['100.64.1.2'],'remotePort':7455}).encode()
                    (state.root/'public.json').write_bytes(fake);(state.app/'CCR-OwnerMacBootstrap.json').write_bytes(fake)
                    state.config['ownerBootstrapSHA256']=adapter.sha(fake);state.receipt['ownerBootstrapSHA256']=adapter.sha(fake);state.seal()
                elif failure=='signature':state.mode='bad-signature'
                elif failure=='expired-provision':state.mode=failure
                elif failure=='keychain':state.ent['keychain-access-groups']=['new group'];state.seal()
                elif failure=='receipt':state.config['preparedArtifactReceiptSHA256']='0'*64
                elif failure in ['input-mutation','repo-source','before-data-change']:state.mode=failure
                with self.assertRaises(adapter.Held):self.invoke(state)
                self.assertEqual((state.installCount,state.launchCount),(0,0))

    def test_after_install_failure_is_held_without_normal_launch_or_automatic_retry(self):
        for failure in ['install-unknown','data-mutation','receipt-mutation','runtime-source','wrong-process','isolated-metadata-change','isolated-data-change']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=self.fixture(directory);state.mode=failure
                with self.assertRaises(adapter.Held):self.invoke(state)
                self.assertEqual(state.installCount,1)
                self.assertEqual(state.launchCount,1 if failure in ['runtime-source','wrong-process','isolated-metadata-change','isolated-data-change'] else 0)
                self.assertEqual(adapter.read(state.work/'prepared-install-attempt.json')['status'],'held-after-install-attempt')
                with self.assertRaisesRegex(adapter.Held,'already_attempted'):self.invoke(state)
                self.assertEqual(state.installCount,1)

    def test_lineage_is_derived_from_pinned_artifact_install_and_metadata(self):
        for failure in [None,'signing','artifact','install','historical-metadata','current-metadata','boolean-only','keychain']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=self.fixture(directory)
                if failure=='signing':(state.root/'signing.json').write_bytes(b'changed')
                if failure=='artifact':(state.priorApp/'Sill').write_bytes(b'changed')
                if failure in ['install','historical-metadata']:
                    label='install' if failure=='install' else 'metadata';path=state.root/(label+'.json')
                    value=adapter.read(path)
                    if failure=='install':value['info']['arguments'][6]=str(state.app)
                    else:value['result']['apps'][0]['url']='file:///other/Sill.app'
                    adapter.write(path,value)
                    reference=adapter.read(state.root/'installed.json')
                    key='installRecordSHA256' if failure=='install' else 'metadataSHA256'
                    reference[key]=adapter.sha(path.read_bytes());adapter.write(state.root/'installed.json',reference)
                    state.config['installedIdentityReceiptSHA256']=adapter.sha((state.root/'installed.json').read_bytes())
                if failure=='current-metadata':state.metadata['url']='file:///other/Sill.app'
                if failure=='keychain':state.ent['keychain-access-groups']=['new-group'];state.seal()
                if failure=='boolean-only':
                    adapter.write(state.root/'installed.json',{'signingReadbackVerified':True,'securityEntitlements':state.ent})
                    state.config['installedIdentityReceiptSHA256']=adapter.sha((state.root/'installed.json').read_bytes())
                if failure:
                    with self.assertRaises(adapter.Held):self.invoke(state)
                    self.assertEqual(state.installCount,0)
                else:
                    with patch.object(adapter,'command',side_effect=state.command):
                        result=adapter.known_installed_lineage(state.config,state.work)
                    self.assertEqual(result['evidenceKind'],'known-installed-artifact-lineage')
                    self.assertFalse(result['remoteSignatureReadback'])
                    self.assertNotIn('keychain-access-groups',result['securityEntitlements'])

    def test_prepared_runtime_and_harness_operational_preflight_reject_drift(self):
        for failure in [None,'staged','context','runtime','process','metadata','runner-missing']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=self.fixture(directory);self.invoke(state)
                if failure=='staged':(state.work/'PreparedArtifact/Sill.app/Sill').write_bytes(b'changed')
                if failure=='context':(state.root/'context.json').write_bytes(b'changed')
                if failure=='runtime':
                    path=state.data/('Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state/runtime.json')
                    value=adapter.read(path);value['executableSHA256']='0'*64;adapter.write(path,value)
                if failure=='process':state.mode='wrong-process'
                if failure=='metadata':state.metadata['bundleVersion']='99'
                with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter.subprocess,'run',side_effect=state.copy):
                    if failure=='runner-missing':
                        with self.assertRaises(KeyError):adapter.harness(state.config,state.work,'testEditAndSave')
                    elif failure:
                        with self.assertRaises(adapter.Held):adapter.prepared_runtime(state.config,state.work)
                    else:self.assertTrue(adapter.prepared_runtime(state.config,state.work)['_running'])
                self.assertFalse(any(row[0]=='xcodebuild' for row in state.commands))

    def test_same_loader_cannot_attest_a_different_debug_implementation(self):
        with tempfile.TemporaryDirectory() as directory:
            state=self.fixture(directory)
            (state.app/'Sill.debug.dylib').write_bytes(b'expected actual implementation image')
            state.seal();original=state.command
            def command(args,*rest,**kwargs):
                value=original(args,*rest,**kwargs)
                if list(map(str,args))[:5]==['xcrun','devicectl','device','process','launch']:
                    path=state.data/('Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state/runtime.json')
                    runtime=adapter.read(path)
                    runtime['codeImages']={'Sill':adapter.sha((state.app/'Sill').read_bytes()),'Sill.debug.dylib':adapter.sha(b'wrong running implementation')}
                    runtime['loadedCodeImagePaths']={'Sill':'/installed/Sill.app/Sill','Sill.debug.dylib':'/installed/Sill.app/Sill.debug.dylib'}
                    adapter.write(path,runtime)
                return value
            state.command=command
            with self.assertRaisesRegex(adapter.Held,'runtime_code_images'):self.invoke(state)


    def test_prepared_code_image_set_and_loaded_paths_are_mandatory(self):
        for failure in [None,'old-runtime','missing-debug','different-debug','different-loader','extra','wrong-loaded','missing-loaded','missing-uuid','wrong-uuid-shape','old-deployment']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=self.fixture(directory);(state.app/'Sill.debug.dylib').write_bytes(b'actual Debug implementation');state.seal()
                deployed=self.invoke(state)
                expected={'Sill':adapter.sha((state.app/'Sill').read_bytes()),'Sill.debug.dylib':adapter.sha((state.app/'Sill.debug.dylib').read_bytes())}
                self.assertEqual(deployed['codeImages'],expected)
                path=state.data/('Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state/runtime.json');runtime=adapter.read(path)
                if failure=='old-runtime':runtime.pop('codeImages');runtime.pop('loadedCodeImagePaths')
                elif failure=='missing-debug':runtime['codeImages'].pop('Sill.debug.dylib')
                elif failure=='different-debug':runtime['codeImages']['Sill.debug.dylib']=adapter.sha(b'other implementation')
                elif failure=='different-loader':runtime['codeImages']['Sill']=adapter.sha(b'other loader')
                elif failure=='extra':runtime['codeImages']['other.dylib']='0'*64
                elif failure=='wrong-loaded':runtime['loadedCodeImagePaths']['Sill.debug.dylib']='/different/Sill.debug.dylib'
                elif failure=='missing-loaded':runtime['loadedCodeImagePaths'].pop('Sill.debug.dylib')
                elif failure=='missing-uuid':runtime.pop('codeImageUUIDs')
                elif failure=='wrong-uuid-shape':runtime['codeImageUUIDs']['Sill.debug.dylib']='not-a-uuid'
                elif failure=='old-deployment':
                    deployed.pop('codeImages');deployed.pop('codeImagesSHA256');adapter.write(state.work/'deployment.json',deployed)
                adapter.write(path,runtime)
                with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter.subprocess,'run',side_effect=state.copy):
                    if failure:
                        with self.assertRaisesRegex(adapter.Held,'code_images'):adapter.prepared_runtime(state.config,state.work)
                    else:self.assertTrue(adapter.prepared_runtime(state.config,state.work)['_running'])


class KnownRunnerContract(unittest.TestCase):
    def fixture(self, state):
        import plistlib,shutil
        bundle='com.ambrion.rea.appaudit.UITests.xctrunner'
        runner=state.root/'Runner.app';runner.mkdir()
        info={'CFBundleIdentifier':bundle,'CFBundleVersion':'1','CFBundleExecutable':'Runner'}
        (runner/'Info.plist').write_bytes(plistlib.dumps(info));(runner/'Runner').write_bytes(b'signed compiled runner fixture')
        binary=runner/'PlugIns/CanvasBridgeUITests.xctest/CanvasBridgeUITests';binary.parent.mkdir(parents=True);binary.write_bytes(b'compiled methods fixture')
        ent={'application-identifier':adapter.NORMAL_TEAM+'.'+bundle,'com.apple.developer.team-identifier':adapter.NORMAL_TEAM,'get-task-allow':True}
        metadata={'bundleIdentifier':bundle,'bundleVersion':'1','containerAccessible':True,'url':'file:///installed/Runner.app'}
        adapter.write(state.root/'runner-signing.json',dict(info,executableSHA256=adapter.sha((runner/'Runner').read_bytes()),entitlements=ent,signatureValid=True))
        adapter.write(state.root/'runner-install.json',{'info':{'outcome':'success','arguments':['devicectl','device','install','app','--device','leased-ipad',str(runner)]},
            'result':{'installedApplications':[{'bundleID':bundle,'installationURL':metadata['url']}]}})
        adapter.write(state.root/'runner-metadata.json',{'result':{'apps':[metadata],'deviceIdentifier':'leased-ipad'}})
        lineage={'schema':'ccr.known-installed-artifact/v1','artifact':str(runner),'artifactManifestSHA256':adapter.digest_value(adapter.artifact_files(runner))}
        for name,key in [('signing','signingReadback'),('install','installRecord'),('metadata','metadata')]:
            path=state.root/('runner-'+name+'.json');lineage[key+'Path']=str(path);lineage[key+'SHA256']=adapter.sha(path.read_bytes())
        adapter.write(state.root/'runner.json',{'schema':'ccr.known-installed-runner/v1','lineage':lineage})
        run=state.root/'preserved.xctestrun';run.write_bytes(plistlib.dumps({'CanvasBridgeUITests':{'IsUITestBundle':True,
            'TestHostPath':'__TESTROOT__/Debug-iphoneos/CanvasBridgeUITests-Runner.app','TestBundlePath':'__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest',
            'UITargetAppPath':'__TESTROOT__/Debug-iphoneos/CanvasBridge.app'}}))
        state.config.update(existingRunnerReceipt=str(state.root/'runner.json'),existingRunnerReceiptSHA256=adapter.sha((state.root/'runner.json').read_bytes()),
            existingXctestrun=str(run),existingXctestrunSHA256=adapter.sha(run.read_bytes()))
        original=state.command;state.running=True;state.runnerMetadata=metadata;state.runnerMethods={'testEditAndSave','testReopenRemoteRevision'}
        def command(args,log=None,*rest,**kwargs):
            args=list(map(str,args))
            if args[0]=='codesign' and Path(args[-1])==runner:
                state.commands.append(args)
                if '--verbose=4' in args:Path(log).write_text('Identifier='+bundle+'\nTeamIdentifier='+adapter.NORMAL_TEAM+'\n')
                return plistlib.dumps(ent).decode() if '--entitlements' in args else ''
            if args[0]=='nm':return '_$fixture_CanvasBridgeUITests_test'
            if args[:2]==['xcrun','swift-demangle']:return '\n'.join('CanvasBridgeUITests.CanvasBridgeUITests.'+m+'()' for m in state.runnerMethods)
            if args[:5]==['xcrun','devicectl','device','info','apps'] and '--bundle-id' in args:
                adapter.write(args[-1],{'result':{'apps':[state.runnerMetadata],'deviceIdentifier':'leased-ipad'}});return ''
            if args[:5]==['xcrun','devicectl','device','info','processes'] and not state.running:
                adapter.write(args[-1],{'result':{'runningProcesses':[]}});return ''
            if args[:5]==['xcrun','devicectl','device','process','terminate']:
                state.running=False;state.commands.append(args);return ''
            if args[0]=='xcodebuild':
                state.commands.append(args);Path(args[args.index('-resultBundlePath')+1]).mkdir()
                state.running=True
                original(['xcrun','devicectl','device','process','launch','--device','leased-ipad',adapter.USER_BUNDLE,
                    '--json-output',str(state.work/'ui-launch.json'),'--','--ccr-test-runtime',state.context['id']])
                return ''
            if args[:5]==['xcrun','xcresulttool','get','test-results','test-details']:
                method=args[-1].split('/')[-1][:-2];return json.dumps(HarnessResultAcceptance().details(method))
            return original(args,log,*rest,**kwargs)
        state.command=command
        return state

    def test_real_prepared_and_runner_preconditions_reach_only_destination_test_command(self):
        for failure in [None,'method','metadata','lineage','xctestrun','prototype']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=PreparedInstallContract().fixture(directory);PreparedInstallContract().invoke(state);self.fixture(state)
                before=Path(state.config['existingXctestrun']).read_bytes()
                if failure=='method':state.runnerMethods.clear()
                if failure=='metadata':state.runnerMetadata=dict(state.runnerMetadata,url='file:///different/Runner.app')
                if failure=='lineage':(state.root/'runner-install.json').write_bytes(b'changed')
                if failure=='xctestrun':state.config['existingXctestrunSHA256']='0'*64
                if failure=='prototype':adapter.write(state.work/'deployment.json',{'bundleIdentifier':adapter.BUNDLE})
                with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter.subprocess,'run',side_effect=state.copy):
                    if failure:
                        with self.assertRaises((adapter.Held,KeyError)):adapter.harness(state.config,state.work,'testEditAndSave')
                    else:
                        result=adapter.harness(state.config,state.work,'testEditAndSave');self.assertTrue(result.is_dir())
                commands=[c for c in state.commands if c[0]=='xcodebuild']
                self.assertEqual(len(commands),0 if failure else 1)
                if commands:
                    self.assertEqual(commands[0][1],'test-without-building')
                    prepared=adapter.plistlib.loads((state.work/'ExistingRunner.xctestrun').read_bytes())['CanvasBridgeUITests']
                    self.assertTrue(prepared['UseDestinationArtifacts']);self.assertNotIn('UITargetAppPath',prepared)
                self.assertEqual(Path(state.config['existingXctestrun']).read_bytes(),before)
                self.assertEqual(state.installCount,1)


    def test_accept_reuses_core_cas_assets_actual_xcresult_and_uuid_cleanup(self):
        import base64,shutil,contextlib
        with tempfile.TemporaryDirectory() as directory:
            state=PreparedInstallContract().fixture(directory);PreparedInstallContract().invoke(state);self.fixture(state)
            state.runnerMethods.update(['testRotateAndSave','testReopenRotatedScene','testLiveRotatedRemoteRevision',
                'testCommentSave','testCommentReopen','testStaleCommentDraftRequiresExplicitDiscard','testRulerToggleAcrossDrawingAndSelection',
                'testReviewEditDraftPreserved','testReviewSaveDraft','testReviewReopen','testReviewLiveRemoteRevision',
                'testReviewGood','testReviewStaleSessionRejected','testReviewMissingSourceRejected'])
            descriptor=state.root/'Scripts/ipad-test-runtime/descriptor.json';adapter.write(descriptor,{'requiredChecks':['native-roundtrip']})
            vault=state.work/'isolated-vault'/state.context['id'];vault.mkdir(parents=True)
            assets=vault/'CCR Canvas/Assets';assets.mkdir(parents=True)
            server={'address':state.context['relayAddress'],'token':'fixture','encoder':'fixture'}
            saved=None
            def request(server,method,path,body=None,authenticated=True):
                nonlocal saved
                if not authenticated:return 401,{}
                if method=='GET':return (200,dict(saved)) if saved else (404,{})
                if saved and body['baseSha256']!=saved['noteSha256']:return 409,{}
                scene=base64.b64decode(body['sceneJSONBase64']);image=base64.b64decode(body['imagePNGBase64'])
                note=b'# fixture note\n'+scene
                (vault/'test.md').write_bytes(note);(assets/adapter.sha(scene)).write_bytes(scene);(assets/adapter.sha(image)).write_bytes(image)
                saved={'sceneJSONBase64':body['sceneJSONBase64'],'revision':body['revision'],'path':'test.md',
                    'noteSha256':adapter.sha(note),'sceneSha256':adapter.sha(scene),'imageSha256':adapter.sha(image)}
                return 200,dict(saved)
            original=state.command
            def command(args,*rest,**kwargs):
                args=list(map(str,args))
                if args[0]=='xcodebuild':
                    method=next(arg.rsplit('/',1)[-1] for arg in args if arg.startswith('-only-testing:'))
                    if method=='testEditAndSave':
                        scene=json.loads(base64.b64decode(saved['sceneJSONBase64']));scene['revision']+=1;scene['nodes'][0]['text']='👩🏽‍💻 앞 '
                        request(server,'PUT','/vault/canvas',{'baseSha256':saved['noteSha256'],'revision':scene['revision'],
                            'sceneJSONBase64':base64.b64encode(json.dumps(scene).encode()).decode(),'imagePNGBase64':base64.b64encode(adapter.pixel()).decode()})
                        adapter.write(state.data/('Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state/CanvasScene.json'),scene)
                if args[:5]==['xcrun','devicectl','device','copy','to']:
                    self.assertEqual(args[args.index('--domain-identifier')+1],adapter.USER_BUNDLE)
                    destination=args[args.index('--destination')+1]
                    self.assertEqual(destination,'Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state')
                    target=state.data/destination;shutil.rmtree(target);target.mkdir();return ''
                if args[:5]==['xcrun','devicectl','device','info','files']:
                    adapter.write(args[-1],{'result':{'domainIdentifier':adapter.USER_BUNDLE,'files':[]}});return ''
                return original(args,*rest,**kwargs)
            state.command=command
            original_copy=state.copy
            def copy(args,**kwargs):
                args=list(map(str,args))
                if args[4]=='to' and '--remove-existing-content' in args:
                    target=state.data/args[args.index('--destination')+1]
                    if target.exists():shutil.rmtree(target)
                return original_copy(args,**kwargs)
            def relay(config,work,source):
                self.assertEqual(config['_runtimeBundle'],adapter.USER_BUNDLE)
                return server,vault,{'borrowed':True,'leaseId':'prepared-existing'}
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(adapter,'command',side_effect=command))
                stack.enter_context(patch.object(adapter.subprocess,'run',side_effect=copy))
                stack.enter_context(patch.object(adapter.time,'sleep'))
                stack.enter_context(patch.object(adapter,'relay_runtime',side_effect=relay))
                stack.enter_context(patch.object(adapter,'acceptance_contract',return_value='existing-contract'))
                stack.enter_context(patch.object(adapter,'encode_scene',side_effect=lambda server,scene:json.dumps(scene).encode()))
                stack.enter_context(patch.object(adapter,'request',side_effect=request))
                for name in ['accept_rotation','accept_comments','accept_review']:
                    stack.enter_context(patch.object(adapter,name,return_value={'independentlyTested':True}))
                result=adapter.accept(state.config,state.work,state.source)
            self.assertEqual(result['status'],'accepted')
            self.assertEqual(adapter.read(state.work/'acceptance.json')['fixtureReset']['status'],'pass')
            reset=adapter.read(state.work/'reset-readback.json');self.assertTrue(all(reset.values()));self.assertTrue(reset['relayPreserved'])
            self.assertEqual(state.installCount,1)
            self.assertTrue(all(c[1]=='test-without-building' for c in state.commands if c[0]=='xcodebuild'))
            self.assertFalse(list(vault.iterdir()))
            self.assertFalse(list((state.data/('Library/Application Support/CCRIntegrationTests/'+state.context['id']+'/state')).iterdir()))


    def test_existing_relay_is_borrowed_without_start_renew_release_or_foreign_vault(self):
        for failure in [None,'lease','configuration','vault','encoder','port','source']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                state=PreparedInstallContract().fixture(directory);work=state.work
                state.config.update(_runtimeBundle=adapter.USER_BUNDLE,relayRepo=str(state.root),relayCommit='c'*40)
                vault=work/'isolated-vault'/state.context['id'];vault.mkdir(parents=True)
                encoder=work/'NativeSceneEncoder';encoder.write_bytes(b'parent-built encoder fixture')
                private={'vault':str(vault),'store':str(work/'relay-store'),'snapshot':str(work/'snapshot.json'),
                    'hidden':str(work/'hidden.json'),'noteAudit':str(work/'review-note-writes.jsonl'),
                    'token':state.context['token'],'host':'192.168.1.2','port':8793,'relayRepo':str(state.root)}
                config_path=work/'relay-private.json';adapter.write(config_path,private)
                current={'leaseId':'existing','owner':adapter.OWNER,'serviceId':'ccr-ipad-integration-relay-8793',
                    'generation':state.source['commit'],'pid':456,'birth':'known-process-birth',
                    'argv':['node',str(state.root/'Scripts/ipad-test-runtime/relay.js'),str(config_path)]}
                receipt=dict(current,schema='ccr.existing-ipad-test-relay/v1',testId=state.context['id'],
                    address=state.context['relayAddress'],vault=str(vault),encoder=str(encoder),encoderSHA256=adapter.sha(encoder.read_bytes()),
                    encoderSourceCommit=state.source['commit'],configurationPath=str(config_path),configurationSHA256=adapter.sha(config_path.read_bytes()))
                adapter.write(work/'existing.json',current)
                if failure=='lease':current['birth']='different'
                if failure=='configuration':private['token']='different';adapter.write(config_path,private)
                if failure=='vault':receipt['vault']=str(state.root/'foreign')
                if failure=='encoder':encoder.write_bytes(b'changed')
                if failure=='source':receipt['encoderSourceCommit']='f'*40
                adapter.write(work/'existing.json',current)
                adapter.write(work/'relay-reference.json',receipt)
                state.config.update(existingRelayReceipt=str(work/'relay-reference.json'),existingRelayReceiptSHA256=adapter.sha((work/'relay-reference.json').read_bytes()))
                policy={'LEASES':work,'is_live':lambda row:True,'expiry':lambda row:dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=5),
                    'now':lambda:dt.datetime.now(dt.timezone.utc),'listener_pids':lambda port:[] if failure=='port' else [456]}
                def command(args,**kwargs):
                    self.assertEqual(args[0],'git')
                    return '' if args[1]=='status' else state.config['relayCommit']
                with patch.object(adapter.runpy,'run_path',return_value=policy),patch.object(adapter,'command',side_effect=command) as commands, \
                     patch.object(adapter,'request',return_value=(200,{})):
                    if failure:
                        with self.assertRaises(adapter.Held):adapter.relay_runtime(state.config,work,state.source)
                    else:
                        _,actual,service=adapter.relay_runtime(state.config,work,state.source)
                        self.assertEqual(actual,vault);self.assertTrue(service['borrowed'])
                self.assertTrue(all(call.args[0][0]=='git' for call in commands.call_args_list))



class XcodeRunnerLineageContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import shlex
        cls.base=Path('/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad')
        cls.history=cls.base/'rea-completion-20261028/adapter-evidence/runner-history'
        cls.approved=adapter.read(cls.history/'result.json')
        cls.action=adapter.read(cls.history/'action.json')
        cls.session=next((cls.history/'diagnostics').rglob('Session-CanvasBridgeUITests-*.log')).read_bytes()
        cls.details=adapter.read(cls.history/'test-details.json')
        cls.result=Path(cls.approved['xcresult']['path'])
        cls.summary=json.loads(adapter.command(['xcrun','xcresulttool','get','test-results','summary','--path',cls.result,'--compact']))
        log=cls.base/'review-only-device-20261026/testReviewReopen.log'
        args=next(shlex.split(line.strip()) for line in log.read_text().splitlines() if line.strip().startswith('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild '))
        cls.reference={'schema':'ccr.known-installed-artifact/v1','installEvidenceKind':'xcode-xcresult',
            'artifact':cls.approved['localArtifact']['artifact'],'artifactManifestSHA256':cls.approved['localArtifact']['manifestSHA256'],
            'metadataPath':cls.approved['preservedMetadata']['path'],'metadataSHA256':cls.approved['inputHashes'][cls.approved['preservedMetadata']['path']],
            'xcode':{'xcresultPath':str(cls.result),'xcresultManifestSHA256':cls.approved['xcresult']['manifestSHA256'],
                'invocationLogPath':str(log),'invocationLogSHA256':cls.approved['inputHashes'][str(log)],
                'invocationSHA256':adapter.digest_value(args),'method':'testReviewReopen',
                'actionSHA256':adapter.digest_value(cls.action),'sessionSHA256':adapter.sha(cls.session),
                'compiledTestsSHA256':cls.approved['localArtifact']['compiledTestsSHA256']}}
        cls.config={'deviceUDID':args[args.index('-destination')+1].removeprefix('id=')}

    def fixture(self,work):
        import copy
        from types import SimpleNamespace
        state=SimpleNamespace(reference=copy.deepcopy(self.reference),action=copy.deepcopy(self.action),
            session=self.session,summary=copy.deepcopy(self.summary),details=copy.deepcopy(self.details),calls=[])
        real=adapter.command
        def command(args,*rest,**kwargs):
            args=list(map(str,args));state.calls.append(args)
            if args[:4]==['xcrun','xcresulttool','get','log']:return json.dumps(state.action)
            if args[:4]==['xcrun','xcresulttool','export','diagnostics']:
                target=Path(args[args.index('--output-path')+1])/'Session-CanvasBridgeUITests-fixture.log';target.write_bytes(state.session);return ''
            if args[:5]==['xcrun','xcresulttool','get','test-results','summary']:return json.dumps(state.summary)
            if args[:5]==['xcrun','xcresulttool','get','test-results','test-details']:return json.dumps(state.details)
            self.assertNotIn('devicectl',args)
            self.assertFalse(args[0]=='xcodebuild' and args[1:]!=['-version'])
            return real(args,*rest,**kwargs)
        state.command=command
        return state


    def test_session_records_reject_prior_echo_and_disconnected_paths(self):
        session=self.session.decode();bundle=adapter.RUNNER_BUNDLE;artifact=Path(self.reference['artifact'])
        echo='\n'.join(line for line in session.splitlines() if 'testBundleURL:' in line or "RemotePath '" in line or
            ('"'+bundle+'" = "') in line and line.rstrip().endswith('Runner.app";'))
        foreign=session.replace('E42A765D-D4C8-4768-8866-F9CD1B30D47D','AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE')
        fragments='\n'.join('[unrelated note '+str(i)+'] '+line for i,line in enumerate(echo.splitlines()))
        cases={'foreign-current':foreign,'old-echo-foreign-current':'[prior diagnostic echo]\n'+echo+'\n[current session]\n'+foreign,
            'disconnected':fragments,'duplicate-session':session+'\n'+session,
            'different-runner-pid':session.replace('CanvasBridgeUITests-Runner[10600:8227188] Loading test bundle','CanvasBridgeUITests-Runner[99999:8227188] Loading test bundle'),
            'different-session-id':session.replace('sessionIdentifier:E6CBDE32-C16C-469E-ACA2-F8B67ED4096E','sessionIdentifier:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'),
            'different-host-pid':session.replace("xcodebuild[20304:133134218] Ambrion의 iPad RemotePath", "xcodebuild[99999:133134218] Ambrion의 iPad RemotePath")}
        self.assertEqual(adapter.xcode_install_identity(self.action,session,artifact,bundle),self.approved['xcodeInstall']['installationURL'])
        for name,text in cases.items():
            with self.subTest(name=name),self.assertRaisesRegex(adapter.Held,'xcode_session'):
                adapter.xcode_install_identity(self.action,text,artifact,bundle)

    def test_actual_official_xcode_history_and_signed_runner_are_accepted_without_device(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(adapter,'device') as device:
            work=Path(directory)
            result=adapter.verify_known_lineage(self.config,work,self.reference,adapter.RUNNER_BUNDLE)
            self.assertEqual(result['evidenceKind'],'known-installed-artifact-lineage-from-xcode')
            self.assertFalse(result['remoteSignatureReadback'])
            self.assertEqual(result['metadataSHA256'],self.approved['preservedMetadata']['runnerRowCanonicalSHA256'])
            self.assertEqual(len(result['provenance']['methods']),21)
            self.assertTrue(set(adapter.RUNNER_CORE_METHODS)<=set(result['provenance']['methods']))
            self.assertEqual(result['provenance']['testBundleBuild']['DTXcodeBuild'],'27A266a')
            device.assert_not_called()

    def test_rejects_real_history_with_broken_correlations_even_after_repinning_fields(self):
        failures=['install-failed','install-exit','bundle','url','local-artifact','session-url','zero-tests','multiple-pass',
            'multiple-runs','details-device','invocation-device','invocation-result','invocation-method','metadata-url','metadata-device','invocation-source',
            'artifact22','source-pin','call-pin','session-pin','action-pin','compiled-pin','duplicate-record']
        for failure in failures:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                work=Path(directory);state=self.fixture(work);ref=state.reference;e=ref['xcode']
                group=state.action['subsections'][0]['subsections'][0]
                record=group['subsections'][1]['messages'][2]['annotations'][2]
                if failure=='install-failed':group['subsections'][0]['result']='failed'
                elif failure=='install-exit':group['subsections'][0]['commandInvocationDetails']['exitCode']=1
                elif failure=='bundle':record['title']=record['title'].replace(adapter.RUNNER_BUNDLE,'another.bundle')
                elif failure=='url':record['title']=record['title'].replace('E42A765D-D4C8-4768-8866-F9CD1B30D47D','00000000-0000-0000-0000-000000000000')
                elif failure=='duplicate-record':group['subsections'][1]['messages'][2]['annotations'].append(dict(record))
                elif failure=='local-artifact':state.action['subsections'][1]['subsections'][0]['testDetails']['runnablePath']=str(work)
                elif failure=='session-url':state.session=state.session.replace(b'E42A765D-D4C8-4768-8866-F9CD1B30D47D',b'00000000-0000-0000-0000-000000000000')
                elif failure=='zero-tests':state.summary.update(totalTestCount=0,passedTests=0)
                elif failure=='multiple-pass':state.summary.update(totalTestCount=2,passedTests=2)
                elif failure=='multiple-runs':state.details['testRuns'].append(dict(state.details['testRuns'][0]))
                elif failure=='details-device':state.details['testRuns'][0]['nodeIdentifier']='another-device'
                elif failure=='invocation-source':
                    path=work/'changed.log';path.write_bytes(Path(e['invocationLogPath']).read_bytes()+b'changed')
                    e['invocationLogPath']=str(path)
                elif failure.startswith('invocation-'):
                    import shlex
                    lines=Path(e['invocationLogPath']).read_text().splitlines()
                    line=next(line for line in lines if line.strip().startswith('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild '))
                    args=shlex.split(line)
                    if failure=='invocation-device':args[args.index('-destination')+1]='id=other'
                    elif failure=='invocation-result':args[args.index('-resultBundlePath')+1]=str(work)
                    else:args[args.index('-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/testReviewReopen')]='-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/testReviewGood'
                    changed=work/'invocation.log';changed.write_text('Command line invocation:\n'+shlex.join(args)+'\n')
                    e.update(invocationLogPath=str(changed),invocationLogSHA256=adapter.sha(changed.read_bytes()),invocationSHA256=adapter.digest_value(args))
                elif failure in ['metadata-url','metadata-device']:
                    metadata=adapter.read(ref['metadataPath'])
                    if failure=='metadata-device':
                        metadata['info']['arguments'][metadata['info']['arguments'].index('--device')+1]='other-device'
                    else:
                        for row in metadata['result']['apps']:
                            if row.get('bundleIdentifier')==adapter.RUNNER_BUNDLE:row['url']='file:///other/Runner.app/'
                    path=work/'metadata.json';adapter.write(path,metadata);ref.update(metadataPath=str(path),metadataSHA256=adapter.sha(path.read_bytes()))
                elif failure=='artifact22':
                    other=self.base/'normal68-device-20261026/HarnessDerivedData/Build/Products/Debug-iphoneos/CanvasBridgeUITests-Runner.app'
                    ref.update(artifact=str(other),artifactManifestSHA256=adapter.digest_value(adapter.artifact_files(other)))
                    e['compiledTestsSHA256']=adapter.sha((other/'PlugIns/CanvasBridgeUITests.xctest/CanvasBridgeUITests').read_bytes())
                if failure=='source-pin':e['xcresultManifestSHA256']='0'*64
                if failure=='call-pin':e['invocationSHA256']='0'*64
                e['actionSHA256']='0'*64 if failure=='action-pin' else adapter.digest_value(state.action)
                e['sessionSHA256']='0'*64 if failure=='session-pin' else adapter.sha(state.session)
                if failure=='compiled-pin':e['compiledTestsSHA256']='0'*64
                with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter,'device') as device:
                    reasons={'install-failed':'xcode_install_not_succeeded','install-exit':'xcode_install_not_succeeded',
                        'bundle':'xcode_install_identity_mismatch','url':'xcode_remote_path_mismatch','local-artifact':'xcode_local_artifact_mismatch',
                        'session-url':'xcode_session_bundle_correlation_missing','zero-tests':'xcode_single_pass_required',
                        'multiple-pass':'xcode_single_pass_required','multiple-runs':'xcresult_execution_count_or_status',
                        'details-device':'xcode_result_device_mismatch','invocation-device':'xcode_invocation_target_mismatch',
                        'invocation-result':'xcode_invocation_target_mismatch','invocation-method':'xcode_invocation_target_mismatch',
                        'metadata-url':'xcode_metadata_mismatch','metadata-device':'xcode_metadata_device_mismatch',
                        'invocation-source':'xcode_invocation_source_changed','artifact22':'xcode_local_artifact_mismatch','source-pin':'xcode_result_source_changed',
                        'call-pin':'xcode_invocation_hash_mismatch','session-pin':'xcode_session_source_changed',
                        'action-pin':'xcode_action_source_changed','compiled-pin':'xcode_compiled_tests_changed','duplicate-record':'xcode_install_record_ambiguous'}
                    with self.assertRaisesRegex(adapter.Held,reasons[failure]):adapter.verify_known_lineage(self.config,work,ref,adapter.RUNNER_BUNDLE)
                    device.assert_not_called()

    def test_existing_core_and_absent_grade_method_use_the_actual_21_method_runner(self):
        for mode in ['core','missing-grade','current-url']:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                work=Path(directory);state=self.fixture(work);path=work/'runner.json'
                adapter.write(path,{'schema':'ccr.known-installed-runner/v1','lineage':state.reference})
                config=dict(self.config,existingRunnerReceipt=str(path),existingRunnerReceiptSHA256=adapter.sha(path.read_bytes()))
                def device(config,args,log):
                    self.assertEqual(args[:3],['info','apps','--bundle-id'])
                    row=dict(self.approved['preservedMetadata']['runnerRow'])
                    if mode=='current-url':row['url']='file:///different/Runner.app/'
                    adapter.write(args[-1],{'result':{'apps':[row],'deviceIdentifier':self.approved['preservedMetadata']['deviceIdentifier']}})
                with patch.object(adapter,'command',side_effect=state.command),patch.object(adapter,'device',side_effect=device) as effect:
                    if mode=='missing-grade':
                        with self.assertRaisesRegex(adapter.Held,'testReviewSelectedGrade'):adapter.verified_runner(config,work,'testReviewSelectedGrade')
                        effect.assert_not_called()
                    elif mode=='current-url':
                        with self.assertRaisesRegex(adapter.Held,'existing_runner_metadata_changed'):adapter.verified_runner(config,work,adapter.RUNNER_CORE_METHODS)
                        self.assertEqual(effect.call_count,1)
                    else:
                        self.assertTrue(adapter.verified_runner(config,work,adapter.RUNNER_CORE_METHODS)['installed'])
                        self.assertEqual(effect.call_count,1)


class SingleAppHoldContract(unittest.TestCase):
    def test_public_entrypoints_hold_before_every_subprocess_and_device_effect(self):
        import contextlib
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            effects = [stack.enter_context(patch.object(adapter,name)) for name in
                       ['command','device','snapshots','lease','relay_runtime','run_live_harness']]
            effects += [stack.enter_context(patch.object(adapter.subprocess,name)) for name in ['run','Popen']]
            work = Path(directory)
            for invoke in [lambda:adapter.deploy({},work,{}), lambda:adapter.accept({},work,{}),
                           lambda:adapter.harness({},work,'testEditAndSave')]:
                with self.assertRaises(adapter.Held):
                    invoke()
            for effect in effects: effect.assert_not_called()
            self.assertEqual(list(work.iterdir()),[])

    def test_cli_held_without_reading_config_or_invoking_xcode(self):
        import subprocess
        for phase in ['deploy','accept']:
            result = subprocess.run([sys.executable,'-B',str(Path(adapter.__file__)),phase,
                                     '--config','/does-not-exist/source-only.json'],capture_output=True,text=True)
            self.assertEqual(result.returncode,2)
            payload = json.loads(result.stdout)
            self.assertEqual(payload['status'],'held')
            self.assertIn('synthetic_owner_bootstrap' if phase=='deploy' else 'FileNotFoundError',payload['reason'])

    def test_existing_prototype_xctestrun_cannot_install_or_be_rewritten(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            run = work/'HarnessDerivedData/Build/Products/prototype.xctestrun'
            run.parent.mkdir(parents=True)
            data = plistlib.dumps({'CanvasBridgeUITests':{'UITargetAppPath':'__TESTROOT__/CanvasBridge.app',
                 'UITargetAppBundleIdentifier':'com.ambrion.rea.appaudit',
                 'DependentProductPaths':['__TESTROOT__/CanvasBridge.app']}})
            run.write_bytes(data)
            with patch.object(adapter,'command') as command, patch.object(adapter.subprocess,'Popen') as popen:
                with self.assertRaisesRegex(adapter.Held,'prepared_deployment_required'):
                    adapter.harness({},work,'testEditAndSave')
                command.assert_not_called(); popen.assert_not_called()
            self.assertEqual(run.read_bytes(),data)

    def test_low_level_install_is_held_even_with_a_valid_lease(self):
        with patch.object(adapter,'lease') as lease, patch.object(adapter,'command') as command:
            with self.assertRaisesRegex(adapter.Held,'single_app_runtime_held'):
                adapter.device({},['install','app','/candidate/Sill.app'],Path('unused'))
            lease.assert_not_called(); command.assert_not_called()

    def test_public_profile_validation_is_not_install_acceptance(self):
        import hashlib, base64
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory).resolve()/'unit-public-profile.json'
            data = json.dumps({'schema':'ccr.owner-mac-bootstrap/v1','macID':'0'*16,
                'fingerprint':base64.urlsafe_b64encode(bytes(32)).decode().rstrip('='),
                'addresses':['100.64.1.2'],'remotePort':7455}).encode()
            profile.write_bytes(data)
            config = {'ownerBootstrapProfile':str(profile),'ownerBootstrapSHA256':hashlib.sha256(data).hexdigest()}
            observed = adapter.owner_bootstrap_identity(config)
            self.assertTrue(observed['schemaValidated'])
            self.assertFalse(observed['installed']); self.assertFalse(observed['hostIdentityAccepted'])
            with self.assertRaisesRegex(adapter.Held,'owner_profile_hash_mismatch'):
                adapter.owner_bootstrap_identity(dict(config,ownerBootstrapSHA256='0'*64))
            with self.assertRaisesRegex(adapter.Held,'single_app_runtime_held'):
                adapter.single_app_installation_gate()
            self.assertEqual(data,profile.read_bytes())

class NativeLoadedUUIDContract(unittest.TestCase):
    @unittest.skipUnless(__import__('os').environ.get('CCR_CODE_UUID_TEST_DIR'),'Set routed output for loaded UUID regression')
    def test_loaded_main_and_debug_uuid_reject_path_replacement(self):
        import os,shutil,plistlib,subprocess,concurrent.futures
        output=Path(os.environ['CCR_CODE_UUID_TEST_DIR']).resolve();output.mkdir(parents=True,exist_ok=True)
        route=json.loads(adapter.command(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad']))
        self.assertTrue(output.is_relative_to(Path(route['path']).resolve()))
        repo=Path(adapter.__file__).resolve().parents[2]
        review=repo.parent/'adapter-runtime-independent-review'
        implementation=(review/'DebugImplementation.swift').read_text()
        implementation=implementation.replace('        try CanvasRuntime.writeRuntimeReceipt(launchState:launch)',r'''        if mode == "replace-main" {
            try FileManager.default.moveItem(at:executable,to:root.appendingPathComponent("still-mapped-main"))
            try FileManager.default.copyItem(at:URL(fileURLWithPath:env["REVIEW_REPLACEMENT_MAIN"]!),to:executable)
        }
        let sentinel = Data("prior pending runtime receipt".utf8)
        let receiptPath = state.appendingPathComponent("runtime.json")
        try sentinel.write(to:receiptPath)
        do { try CanvasRuntime.writeRuntimeReceipt(launchState:launch) }
        catch {
            let preserved = try Data(contentsOf:receiptPath) == sentinel
            let observation: [String:Any] = ["executingValue":reviewValue(),"priorPreserved":preserved]
            try JSONSerialization.data(withJSONObject:observation).write(to:root.appendingPathComponent("rejected.json"))
            return 11
        }''')
        swift=output/'Implementation.swift';swift.write_text(implementation)
        loader=output/'Loader.c';loader.write_text('#ifdef MAIN_B\n__attribute__((used)) volatile int loader_version=2;\n#else\n__attribute__((used)) volatile int loader_version=1;\n#endif\n'+(review/'DebugLoader.c').read_text())
        info=output/'Info.plist';info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.ccr.loaded-uuid.fixture','CFBundleExecutable':'Sill','CFBundleVersion':'1','CCRSourceCommit':'a'*40,'CCRSourceTree':'b'*40}))
        for name,flags in [('main-A',[]),('main-B',['-DMAIN_B'])]:
            adapter.command(['xcrun','clang',*flags,loader,'-Wl,-sectcreate,__TEXT,__info_plist,'+str(info),'-o',output/name],output/(name+'.log'))
        def build(name):
            adapter.command(['xcrun','swiftc','-D','DEBUG',*(['-D','REVIEW_VARIANT_B'] if name=='B' else []),
                '-swift-version','5','-parse-as-library','-emit-library','-module-cache-path',output/'modules',
                repo/'iOSClient/CanvasBridge/CanvasModel.swift',swift,'-o',output/(name+'.dylib')],output/(name+'.log'))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(build,['A','B']))
        cases=[]
        for name,variant,mode,expected in [('healthy-A','A','healthy',0),('healthy-B','B','healthy',0),
                ('replaced-debug','A','replace-loaded',11),('replaced-main','A','replace-main',11),('removed-debug','A','remove-loaded',11)]:
            case=output/name;app=case/'Sill.app';app.mkdir(parents=True)
            shutil.copyfile(output/'main-A',app/'Sill');(app/'Sill').chmod(0o700)
            shutil.copyfile(output/(variant+'.dylib'),app/'Sill.debug.dylib');shutil.copyfile(info,app/'Info.plist')
            env=dict(adapter.ENV,REVIEW_CASE_ROOT=str(case),REVIEW_MODE=mode,REVIEW_REPLACEMENT=str(output/'B.dylib'),REVIEW_REPLACEMENT_MAIN=str(output/'main-B'))
            run=subprocess.run([app/'Sill'],env=env,capture_output=True,text=True,timeout=30)
            (case/'run.log').write_text(run.stdout+run.stderr)
            self.assertEqual(run.returncode,expected,name+': '+run.stdout+run.stderr)
            if expected:
                observed=adapter.read(case/'rejected.json');self.assertEqual(observed['executingValue'],1);self.assertTrue(observed['priorPreserved'])
                self.assertFalse((case/'native-receipt.json').exists())
            else:
                receipt=adapter.read(case/'native-receipt.json');self.assertEqual(set(receipt['codeImageUUIDs']),{'Sill','Sill.debug.dylib'})
                for image in receipt['codeImages']:
                    identity=adapter.command(['dwarfdump','--uuid',app/image]).split()[1].replace('-','').lower()
                    self.assertEqual(receipt['codeImageUUIDs'][image],identity)
                    self.assertEqual(receipt['codeImages'][image],adapter.sha((app/image).read_bytes()))
            cases.append({'name':name,'exitCode':run.returncode,'passed':True})
        adapter.write(output/'native-cases.json',{'cases':cases})
        sdk=adapter.command(['xcrun','--sdk','iphoneos','--show-sdk-path']).strip()
        adapter.command(['xcrun','swiftc','-typecheck','-D','DEBUG','-swift-version','5','-parse-as-library','-sdk',sdk,
            '-target','arm64-apple-ios17.0','-module-cache-path',output/'ios-modules',repo/'iOSClient/CanvasBridge/CanvasModel.swift'],output/'ios27-typecheck.log')


class NativeCodeImagesContract(unittest.TestCase):
    @unittest.skipUnless(__import__('os').environ.get('CCR_CODE_IMAGES_TEST_DIR'),'Set a routed output directory for native/SDK checks')
    def test_actual_receipt_hashes_only_loaded_main_and_debug_images(self):
        import os,subprocess,plistlib
        output=Path(os.environ['CCR_CODE_IMAGES_TEST_DIR']).resolve();output.mkdir(parents=True,exist_ok=True)
        route=json.loads(adapter.command(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad']))
        self.assertTrue(output.is_relative_to(Path(route['path']).resolve()))
        repo=Path(adapter.__file__).resolve().parents[2];source=output/'CodeImageCheck.swift'
        source.write_text(r"""import Foundation
import CryptoKit
import Darwin
@main struct CodeImageCheck {
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let support = root.appendingPathComponent("support",isDirectory:true)
        let id = UUID().uuidString.lowercased()
        let testRoot = support.appendingPathComponent("CCRIntegrationTests/" + id,isDirectory:true)
        let state = testRoot.appendingPathComponent("state",isDirectory:true)
        try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true)
        let context: [String:String] = ["schema":"ccr.ipad-test-context/v1","id":id,
            "commit":String(repeating:"a",count:40),"tree":String(repeating:"b",count:40),
            "relayAddress":"http://192.168.1.2:8793","token":"native-isolated-fixture-reference"]
        try JSONSerialization.data(withJSONObject:context).write(to:testRoot.appendingPathComponent("context.json"))
        let launch = CanvasRuntime.resolve(arguments:["fixture","--ccr-test-runtime",id],applicationSupport:support,
            sourceCommit:context["commit"],sourceTree:context["tree"])
        let receiptURL = state.appendingPathComponent("runtime.json")
        let executable = Bundle.main.executableURL!
        let image = executable.deletingLastPathComponent().appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        let preparedImage = root.appendingPathComponent("prepared-implementation.dylib")
        try CanvasRuntime.writeRuntimeReceipt(launchState:launch)
        func read() throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:receiptURL)) as! [String:Any] }
        let first = try read()
        precondition((first["codeImages"] as! [String:String]).count == 1)
        let firstBytes = try Data(contentsOf:receiptURL)
        try FileManager.default.copyItem(at:preparedImage,to:image)
        var rejected = false
        do { try CanvasRuntime.writeRuntimeReceipt(launchState:launch) } catch { rejected = true }
        precondition(rejected,"present but unloaded implementation must be rejected")
        let preservedBytes = try Data(contentsOf:receiptURL)
        precondition(preservedBytes == firstBytes,"failed receipt must preserve prior bytes")
        guard let handle = dlopen(image.path,RTLD_NOW | RTLD_LOCAL) else { preconditionFailure("fixture dylib failed to load") }
        defer { dlclose(handle) }
        try CanvasRuntime.writeRuntimeReceipt(launchState:launch)
        let second = try read()
        let expected = try Dictionary(uniqueKeysWithValues:[executable,image].map { url in
            (url.lastPathComponent,SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined())
        })
        precondition(second["codeImages"] as! [String:String] == expected)
        precondition(second["executableSHA256"] as! String == first["executableSHA256"] as! String,"same loader fixture")
        let paths = second["loadedCodeImagePaths"] as! [String:String]
        precondition(paths.count == 2 && paths[image.lastPathComponent] == image.resolvingSymlinksInPath().path)
        try Data(contentsOf:receiptURL).write(to:root.appendingPathComponent("verified-native-receipt.json"))
        print("PASS real loader and dlopen implementation SHA/path; unloaded image rejected and prior receipt preserved")
    }
}
""")
        c=output/'implementation.c';c.write_text('int ccr_receipt_fixture(void) { return 42; }\n')
        adapter.command(['xcrun','clang','-dynamiclib',c,'-o',output/'prepared-implementation.dylib'],output/'dylib-build.log')
        info=output/'FixtureInfo.plist';info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.ccr.receipt.native-fixture',
            'CFBundleExecutable':'ReceiptCheck','CFBundleVersion':'1','CCRSourceCommit':'a'*40,'CCRSourceTree':'b'*40}))
        executable=output/'ReceiptCheck'
        adapter.command(['xcrun','swiftc','-D','DEBUG','-swift-version','5','-module-cache-path',output/'modules','-parse-as-library',
            repo/'iOSClient/CanvasBridge/CanvasModel.swift',source,'-Xlinker','-sectcreate','-Xlinker','__TEXT',
            '-Xlinker','__info_plist','-Xlinker',info,'-o',executable],output/'native-build.log')
        adapter.command([executable,output],output/'native-run.log')
        actual=adapter.read(output/'verified-native-receipt.json')
        self.assertEqual(actual['codeImages'],{'ReceiptCheck':adapter.sha(executable.read_bytes()),
            'ReceiptCheck.debug.dylib':adapter.sha((output/'ReceiptCheck.debug.dylib').read_bytes())})
        sdk=adapter.command(['xcrun','--sdk','iphoneos','--show-sdk-path']).strip()
        adapter.command(['xcrun','swiftc','-typecheck','-D','DEBUG','-swift-version','5','-parse-as-library',
            '-sdk',sdk,'-target','arm64-apple-ios17.0','-module-cache-path',output/'ios-modules',
            repo/'iOSClient/CanvasBridge/CanvasModel.swift'],output/'ios27-typecheck.log')


class PreservationSnapshotContract(unittest.TestCase):
    def test_full_documents_preferences_and_metadata_are_checked_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            def device(config,args,log):
                adapter.write(args[-1],{'result':{'build':'70','bundleIdentifier':adapter.USER_BUNDLE}})
            copied = []
            def copy(config,work,source,target,**kwargs):
                self.assertEqual(kwargs['bundle'],adapter.USER_BUNDLE)
                copied.append(str(source));target=Path(target)
                if source in ['Documents','Library/Preferences','Library/Application Support/CanvasConflictRecovery']:
                    target.mkdir(parents=True)
                    (target/'one').write_bytes(b'normal preserved bytes')
                    (target/'two').write_bytes(b'other bytes')
                else: target.write_bytes(b'protected scene or recovery')
                return True
            with patch.object(adapter,'device',side_effect=device),patch.object(adapter,'copy_file',side_effect=copy):
                before=adapter.snapshots({},work,'before')
            self.assertIn('Documents',copied);self.assertIn('Library/Preferences',copied)
            self.assertIn('Library/Application Support/CanvasNoteEdit/recovery.json',copied)
            after=json.loads(json.dumps(before));after['installedUserApp']['build']='71'
            self.assertTrue(adapter.same_user_data(before,after))
            after['Library/Preferences']['two']='changed hash'
            self.assertFalse(adapter.same_user_data(before,after))
            after=json.loads(json.dumps(before));after['Documents']['one']='changed hash'
            self.assertFalse(adapter.same_user_data(before,after))

class ConflictRecoverySnapshotContract(unittest.TestCase):
    def test_new_conflict_recovery_directory_changes_the_preservation_proof(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);work=root/'evidence';work.mkdir()
            source=root/'source';source.mkdir();recovery=source/'Library/Application Support/CanvasConflictRecovery'
            for relative in ['Documents','Library/Preferences']:
                target=source/relative;target.mkdir(parents=True);(target/'stable').write_bytes(b'unchanged normal bytes')
            def device(config,args,log):adapter.write(args[-1],{'result':{'apps':[]}})
            def copy(config,work,relative,target,**kwargs):
                self.assertEqual(kwargs['bundle'],adapter.USER_BUNDLE)
                src=source/relative
                if not src.exists():return False
                if src.is_dir():shutil.copytree(src,target)
                else:shutil.copyfile(src,target)
                return True
            with patch.object(adapter,'device',side_effect=device),patch.object(adapter,'copy_file',side_effect=copy):
                before=adapter.snapshots({},work,'absent')
                recovery.mkdir(parents=True);(recovery/'CanvasConflictChoice.json').write_bytes(b'unique current conflict choice')
                after=adapter.snapshots({},work,'created')
            self.assertFalse(adapter.same_user_data(before,after),'new conflict recovery source must change preservation proof')


    def test_complete_directory_absence_addition_edit_removal_and_boundaries(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);work=root/'evidence';work.mkdir()
            local='CanvasConflictLocal-'+str(uuid.uuid4())+'.json';attempt='CanvasConflictAttempt-'+str(uuid.uuid4())+'.json'
            baseline={'CanvasConflictChoice.json':b'choice original bytes',local:b'only local scene',attempt:b'only in-flight attempt',
                'nested/unfiltered.bin':b'also protected; no filename prefix filter'}
            versions={'absent':None,'empty':{},'really-empty':{},'full':baseline,'same':dict(baseline),'added':dict(baseline,**{'another-file':b'unique new source'}),
                'changed':dict(baseline,**{'CanvasConflictChoice.json':b'changed choice'}),'removed':{k:v for k,v in baseline.items() if k!=local},'gone':None}
            for name,files in versions.items():
                source=root/name;source.mkdir()
                for relative in ['Documents','Library/Preferences']:
                    target=source/relative;target.mkdir(parents=True);(target/'stable').write_bytes(b'unchanged base data')
                if files is not None:
                    folder=source/'Library/Application Support/CanvasConflictRecovery';folder.mkdir(parents=True)
                    if name != 'really-empty':(folder/'empty-child').mkdir()
                    for key,value in files.items():
                        target=folder/key;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(value)
            selected=root/'absent';copied=[]
            def device(config,args,log):adapter.write(args[-1],{'result':{'apps':[]}})
            def copy(config,work,relative,target,**kwargs):
                self.assertEqual(kwargs['bundle'],adapter.USER_BUNDLE);copied.append(relative)
                source=selected/relative
                if not source.exists():return False
                if source.is_dir():shutil.copytree(source,target,symlinks=True)
                else:shutil.copyfile(source,target)
                return True
            records={}
            with patch.object(adapter,'device',side_effect=device),patch.object(adapter,'copy_file',side_effect=copy):
                for name in versions:
                    selected=root/name;records[name]=adapter.snapshots({},work,name)
                self.assertIsNone(records['absent']['CanvasConflictRecovery'])
                self.assertEqual(records['empty']['CanvasConflictRecovery'],{'empty-child/':None})
                self.assertEqual(records['really-empty']['CanvasConflictRecovery'],{})
                self.assertFalse(adapter.same_user_data(records['absent'],records['really-empty']))
                expected={k:adapter.sha(v) for k,v in baseline.items()};expected.update({'empty-child/':None,'nested/':None})
                self.assertEqual(records['full']['CanvasConflictRecovery'],expected)
                self.assertTrue(adapter.same_user_data(records['full'],records['same']))
                for name in ['absent','empty','really-empty','added','changed','removed','gone']:
                    self.assertFalse(adapter.same_user_data(records['full'],records[name]),name)
                self.assertFalse(adapter.same_user_data(records['absent'],records['empty']))
                legacy=dict(records['absent']);legacy.pop('CanvasConflictRecovery')
                self.assertFalse(adapter.same_user_data(legacy,records['absent']),'uncaptured old baseline is not verified absence')
                selected=root/'full';before=(work/'full.json').read_bytes()
                with self.assertRaisesRegex(adapter.Held,'destination_exists'):adapter.snapshots({},work,'full')
                self.assertEqual(before,(work/'full.json').read_bytes())
                folder=selected/'Library/Application Support/CanvasConflictRecovery'
                (folder/'unexpected-link').symlink_to(selected/'Documents/stable')
                with self.assertRaisesRegex(adapter.Held,'snapshot_symlink'):adapter.snapshots({},work,'symlink-refused')
            self.assertIn('Library/Application Support/CanvasConflictRecovery',copied)
            self.assertNotIn('Library/Application Support',copied)
            self.assertFalse(any('CCRIntegrationTests' in path for path in copied))


class DestinationArtifactContract(unittest.TestCase):
    def test_normal_bundle_and_existing_runner_only_for_v1_and_v2(self):
        import plistlib
        runner = {'schema':'ccr.existing-xctest-runner/v1','installed':True,'team':adapter.NORMAL_TEAM,
            'bundleIdentifier':'com.ambrion.rea.appaudit.UITests.xctrunner',
            'testBundleRelativePath':'__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest'}
        for version in [1,2]:
            target = {'IsUITestBundle':True,'TestHostPath':'old.app','TestBundlePath':'old.xctest',
                'UITargetAppPath':'CanvasBridge.app','DependentProductPaths':['CanvasBridge.app'],
                'TestingEnvironmentVariables':{},'EnvironmentVariables':{'CCR_TEST_BUNDLE':adapter.BUNDLE}}
            payload = {'TestConfigurations':[{'IsEnabled':True,'TestTargets':[target]}]} if version==2 else {'CanvasBridgeUITests':target}
            before = plistlib.dumps(payload)
            result = adapter.destination_artifacts_run(payload,runner,str(uuid.uuid4()))
            actual = result['TestConfigurations'][0]['TestTargets'][0] if version==2 else result['CanvasBridgeUITests']
            self.assertIs(actual['UseDestinationArtifacts'],True)
            self.assertEqual(actual['TestHostBundleIdentifier'],runner['bundleIdentifier'])
            self.assertEqual(actual['UITargetAppBundleIdentifier'],adapter.USER_BUNDLE)
            self.assertEqual(actual['EnvironmentVariables']['CCR_TEST_BUNDLE'],adapter.USER_BUNDLE)
            for key in ['TestHostPath','TestBundlePath','UITargetAppPath','DependentProductPaths']:
                self.assertNotIn(key,actual)
            self.assertEqual(plistlib.dumps(payload),before)
            for changed in [dict(runner,installed=False),dict(runner,team='another'),dict(runner,bundleIdentifier='new.runner')]:
                with self.assertRaises(adapter.Held): adapter.destination_artifacts_run(payload,changed,str(uuid.uuid4()))

    def test_prepared_harness_never_builds_and_preserves_input_run(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            original = work/'original.xctestrun'
            original.write_bytes(plistlib.dumps({'CanvasBridgeUITests':{'IsUITestBundle':True,
                'TestHostPath':'CanvasBridgeUITests-Runner.app','UITargetAppPath':'CanvasBridge.app',
                'TestBundlePath':'CanvasBridgeUITests.xctest','DependentProductPaths':['CanvasBridge.app'],
                'TestingEnvironmentVariables':{}}}))
            before = original.read_bytes()
            config = existing_runner_fixture(work,original)
            adapter.write(work/'deployment.json',{'testId':str(uuid.uuid4()),'bundleIdentifier':adapter.USER_BUNDLE,
                'configuration':'Debug','sourceReadbackVerified':True})
            with patch.object(adapter,'prepared_runtime',return_value=adapter.read(work/'deployment.json')), \
                 patch.object(adapter,'verified_runner',return_value=adapter.read(work/'existing-runner.json')), patch.object(adapter,'lease'), \
                 patch.object(adapter,'actual_xcresult'), patch.object(adapter,'command') as command:
                adapter.harness(config,work,'testEditAndSave')
                command.assert_called_once()
                args = command.call_args.args[0]
                self.assertEqual(args[:2],['xcodebuild','test-without-building'])
                self.assertNotIn('build-for-testing',args)
            self.assertEqual(original.read_bytes(),before)
            prepared = plistlib.loads((work/'ExistingRunner.xctestrun').read_bytes())['CanvasBridgeUITests']
            self.assertTrue(prepared['UseDestinationArtifacts'])
            with patch.object(adapter,'prepared_runtime',return_value=adapter.read(work/'deployment.json')), \
                 patch.object(adapter,'verified_runner',return_value=adapter.read(work/'existing-runner.json')), patch.object(adapter,'lease'), \
                 patch.object(adapter,'command') as command:
                with self.assertRaisesRegex(adapter.Held,'existing_xctestrun_changed'):
                    adapter.harness(dict(config,existingXctestrunSHA256='0'*64),work,'testEditAndSave')
                command.assert_not_called()


class NativeDefaultsContract(unittest.TestCase):
    @unittest.skipUnless(__import__('os').environ.get('CCR_NATIVE_ADAPTER_TEST_DIR'),
                         'Set the routed evidence directory to run Apple SDK checks')
    def test_actual_debug_store_uses_only_context_preferences(self):
        import os, subprocess, plistlib, hashlib
        output = Path(os.environ['CCR_NATIVE_ADAPTER_TEST_DIR']).resolve()
        route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path',
            'development-archive','--project','BT_CCR-ipad'],text=True))
        self.assertTrue(output.is_relative_to(Path(route['path']).resolve()))
        output.mkdir(parents=True,exist_ok=True)
        repo = Path(adapter.__file__).resolve().parents[2]
        source = output/'DefaultsCheck.swift'
        source.write_text(r"""import Foundation
import PencilKit
final class ForbiddenDefaults: UserDefaults {
    override func object(forKey key: String) -> Any? { preconditionFailure("normal defaults read") }
    override func string(forKey key: String) -> String? { preconditionFailure("normal defaults read") }
    override func set(_ value: Any?, forKey key: String) { preconditionFailure("normal defaults write") }
}
@main struct DefaultsCheck {
    @MainActor static func main() throws {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        precondition(support.path.hasPrefix(home + "/"))
        let normal = ForbiddenDefaults(suiteName:"ccr-test-unused-" + UUID().uuidString)!
        let preferences = URL(fileURLWithPath:home).appendingPathComponent("Library/Preferences")
        func hashes() throws -> [String:String] {
            let items = FileManager.default.enumerator(at:preferences,includingPropertiesForKeys:[.isRegularFileKey])!
            var values: [String:String] = [:]
            for case let url as URL in items where try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                values[url.path] = CanvasPacket.sha(try Data(contentsOf:url))
            }
            return values
        }
        let before = try hashes()
        precondition(before.count >= 2,"nonempty normal Preferences fixture required")
        let normalScene = support.appendingPathComponent("CanvasScene.json")
        let sceneBefore = try Data(contentsOf:normalScene)
        let store = CanvasStore(defaults:normal)
        precondition(store.sceneRecoveryNotice.isEmpty,"isolated Store must not parse corrupt normal scene")
        precondition(store.eraserStyle == .partial && store.eraserSize == .standard)
        store.eraserStyle = .stroke; store.eraserSize = .broad
        if ProcessInfo.processInfo.environment["EXPECT_INVALID"] == "1" {
            guard case .invalid = CanvasRuntime.launch else { preconditionFailure("invalid context required") }
            precondition(CanvasRuntime.defaults(overriding:normal).object(forKey:CanvasStore.eraserStyleKey) == nil)
            print("PASS invalid context never falls back to standard defaults")
        } else {
            guard case .isolated = CanvasRuntime.launch else { preconditionFailure("isolated context required") }
            let file = try CanvasRuntime.stateURL(.preferences)
            let values = try JSONSerialization.jsonObject(with:CanvasLocalFile.read(file)) as! [String:Any]
            precondition(values[CanvasStore.eraserStyleKey] as? String == CanvasEraserStyle.stroke.rawValue)
            let reopened = CanvasStore(defaults:normal)
            precondition(reopened.eraserStyle == .stroke && reopened.eraserSize == .broad)
            let corrupt = Data("broken isolated preferences".utf8)
            try CanvasLocalFile.write(corrupt,to:file)
            reopened.eraserStyle = .partial
            let preserved = try CanvasLocalFile.read(file)
            precondition(preserved == corrupt)
            print("PASS isolated settings save and reopen in context JSON; corrupt bytes remain intact")
        }
        let after = try hashes()
        precondition(after == before)
        let sceneAfter = try Data(contentsOf:normalScene)
        precondition(sceneBefore == sceneAfter)
        print("PASS entire normal Preferences and protected normal scene remain byte-identical")
    }
}
""")
        info = output/'DefaultsCheck.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier':adapter.USER_BUNDLE,'CFBundleName':'DefaultsCheck',
            'CFBundleExecutable':'defaults-check','CFBundleVersion':'70','CCRSourceCommit':'a'*40,'CCRSourceTree':'b'*40}))
        command = ['xcrun','swiftc','-D','DEBUG','-swift-version','5','-module-cache-path',str(output/'modules'),
            '-target','arm64e-apple-macos27.0','-parse-as-library',str(repo/'iOSClient/CanvasBridge/CanvasModel.swift'),
            str(repo/'iOSClient/CanvasBridge/CanvasStore.swift'),str(source),'-Xlinker','-sectcreate','-Xlinker','__TEXT',
            '-Xlinker','__info_plist','-Xlinker',str(info),'-o',str(output/'defaults-check')]
        with (output/'defaults-compile.log').open('w') as log:
            result = subprocess.run(command,env=adapter.ENV,stdout=log,stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode,0,(output/'defaults-compile.log').read_text()[-4000:])
        for invalid in [False,True]:
            home = output/('home-'+uuid.uuid4().hex);home.mkdir()
            test_id = str(uuid.uuid4())
            state = home/'Library/Application Support/CCRIntegrationTests'/test_id/'state'
            state.mkdir(parents=True)
            (home/'Library/Application Support/CanvasScene.json').write_bytes(b'protected corrupt normal scene: do not parse or replace')
            preferences = home/'Library/Preferences';preferences.mkdir(parents=True)
            (preferences/(adapter.USER_BUNDLE + '.plist')).write_bytes(plistlib.dumps({
                'Sill.savedMacs':'기존 Mac 참조', 'iPadDesiredAudio.v1':{'microphone':True,'speaker':False},
                'canvasEraserStyle':'획 전체 지우기','canvasPartialEraserWidth':80}))
            (preferences/'other-domain.plist').write_bytes(plistlib.dumps({'untouched':b'original bytes'}))
            adapter.write(state.parent/'context.json',{'schema':'ccr.ipad-test-context/v1','id':test_id,
                'commit':'a'*40,'tree':'b'*40,'relayAddress':'http://192.168.1.2:8793','token':'test-only-context-token-1234567890'})
            args = [str(output/'defaults-check'),'--ccr-test-runtime',str(uuid.uuid4()) if invalid else test_id]
            env = dict(adapter.ENV,HOME=str(home),CFFIXED_USER_HOME=str(home),EXPECT_INVALID='1' if invalid else '0')
            result = subprocess.run(args,env=env,capture_output=True,text=True,timeout=60)
            (output/('defaults-invalid.log' if invalid else 'defaults-isolated.log')).write_text(result.stdout+result.stderr)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

class AdapterContract(unittest.TestCase):
    def test_deploy_never_requests_provisioning_updates(self):
        import ast
        import inspect
        tree = ast.parse(inspect.getsource(adapter.deploy))
        literals = [node.value for node in ast.walk(tree) if isinstance(node, ast.Constant)]
        self.assertNotIn('-allowProvisioningUpdates', literals)
        self.assertNotIn('-allowProvisioningDeviceRegistration', literals)

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
            save_revisions = None
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
                    scene['revision'] = next(save_revisions) if save_revisions is not None else scene['revision'] + 1
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
                for revisions in [(3,3),(4,3),(3,4)]:
                    with self.subTest(saveRevisions=revisions):
                        scene = adapter.fixture(scene['id'])
                        save_revisions = iter(revisions)
                        methods.clear()
                        case_work = work / ('revisions-' + '-'.join(map(str,revisions)))
                        adapter.write(case_work/'context.json',{'test':'isolated'})
                        if revisions in [(3,3),(4,3)]:
                            with self.assertRaisesRegex(adapter.Held,'comment_revision_not_increased'):
                                adapter.accept_comments({},case_work,{},scene['id'])
                            self.assertEqual(methods,['testCommentSave','testCommentReopen','testCommentSave'])
                            self.assertFalse((case_work/'comment-functional-readback.json').exists())
                        else:
                            proof = adapter.accept_comments({},case_work,{},scene['id'])
                            self.assertEqual([row['vault']['revision'] for row in proof['edits']],[3,4])
                            self.assertEqual(proof['baseline']['revision'],2)
                            self.assertEqual(proof['commentID'],comment_id)

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
            with patch.object(adapter,'single_app_installation_gate'), patch.object(adapter,'lease'), patch.object(adapter,'snapshots',return_value={}), patch.object(adapter,'command',side_effect=stop_after_build), patch.object(adapter,'device') as device:
                with self.assertRaisesRegex(adapter.Held,'stop_after_build_input_check'):
                    adapter.deploy(config,work,{'commit':'a'*40,'tree':'b'*40})
                device.assert_not_called()

    def test_build_cache_cannot_equal_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(adapter,'single_app_installation_gate'),patch.object(adapter,'lease'),patch.object(adapter,'snapshots',return_value={}),patch.object(adapter,'command') as command:
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

    def exercise(self, root, details, live=False, exists=True, variables=None):
        import plistlib
        run = root / 'HarnessDerivedData/Build/Products/test.xctestrun'
        run.parent.mkdir(parents=True)
        run.write_bytes(plistlib.dumps({'CanvasBridgeUITests':{'IsUITestBundle':True,'EnvironmentVariables':{}}}))
        adapter.write(root/'deployment.json',{'testId':str(uuid.uuid4()),'bundleIdentifier':adapter.USER_BUNDLE,'configuration':'Debug','sourceReadbackVerified':True})
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
        with patch.object(adapter,'prepared_runtime',return_value=adapter.read(root/'deployment.json')), \
             patch.object(adapter,'verified_runner',return_value={'schema':'ccr.existing-xctest-runner/v1','installed':True,'team':adapter.NORMAL_TEAM,
                 'bundleIdentifier':'com.ambrion.rea.appaudit.UITests.xctrunner','testBundleRelativePath':'__TESTHOST__/PlugIns/CanvasBridgeUITests.xctest'}), \
             patch.object(adapter,'lease'), patch.object(adapter,'command',side_effect=command) as cmd, \
             patch.object(adapter,'run_live_harness',side_effect=run_live):
            result = adapter.harness(existing_runner_fixture(root,run),root,'testReviewReopen',variables,
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

    def test_harness_preserves_environment_utf8_bytes_in_written_xctestrun(self):
        import plistlib
        card = adapter.review_fixture('isolated')
        variables = {
            'CCR_REVIEW_DRAFT':adapter.review_text(card,card['question'] + ' / UIKit question',
                                                  card['answer'] + ' / UIKit answer',card['metadata']),
            'CCR_REVIEW_CRLF':'첫 줄\r\n다음 줄\r\n',
            'CCR_REVIEW_CR':'\r앞\r가운데\r끝\r',
            'CCR_REVIEW_NFD':'e\u0301 한',
            'CCR_REVIEW_EMOJI':'👩🏽‍💻 🧑‍🚀',
            'CCR_REVIEW_XML':'<&>"\'\t\n',
            'CCR_REVIEW_EMPTY':'',
            'CCR_COMMENT_TEXT':'댓글\r\n e\u0301 👩🏽‍💻\r',
        }
        for live in [False,True]:
            with self.subTest(live=live), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.exercise(root,self.details('testReviewReopen'),live,variables=variables)
                run = root / 'ExistingRunner.xctestrun'
                loaded = plistlib.loads(run.read_bytes())['CanvasBridgeUITests']['EnvironmentVariables']
                for name, text in variables.items():
                    with self.subTest(variable=name):
                        self.assertEqual(loaded[name].encode('utf-8'),text.encode('utf-8'))
                self.assertEqual(loaded['CCR_TEST_RUNTIME_ID'],adapter.read(root/'deployment.json')['testId'])
                self.assertEqual(loaded['CCR_TEST_BUNDLE'],adapter.USER_BUNDLE)

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
        expected = {'relayAddress':'http://127.0.0.1:8793','base':{
            'path':'note.md','text':'base','sha256':adapter.sha(b'base'),'modifiedAt':'fixture'},'draft':'draft'}
        valid = dict(expected,schemaVersion=1,sceneID='12345678-1234-4234-8234-123456789abc')
        for field,value in [(None,None),('schemaVersion',True),('sceneID',3),('draft',None),
                            ('base',[]),('submittedText',3),('nodeID',3)]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                raw = json.dumps(dict(valid,**({field:value} if field else {}))).encode()
                envelope = {'schemaVersion':1,'sha256':adapter.sha(raw),'payload':base64.b64encode(raw).decode()}
                with patch.object(adapter,'copy_file'), patch.object(adapter,'read',return_value=envelope):
                    if field is None:
                        adapter.review_journal({},Path(directory),valid['sceneID'],'draft',expected)
                    else:
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

class FourGradeAcceptance(unittest.TestCase):
    def exercise(self, directory, failure=None, corrupt_button=None):
        import re
        import urllib.parse
        work = Path(directory); vault = work / 'isolated-vault'; vault.mkdir()
        test_id = '12345678-1234-4234-8234-123456789abc'
        source = {'commit':'14e941099ca5d27bb4c1df171849d601a14a1455',
                  'tree':'4c1081a9a0e154e4ce2980d80d6d29e69edf1499'}
        app = work / 'Artifact/Sill.app'; app.mkdir(parents=True)
        (app / 'Sill').write_bytes(b'offline diagnostic executable')
        import plistlib
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=adapter.BUNDLE,
            CFBundleExecutable='Sill',CCRSourceCommit=source['commit'],CCRSourceTree=source['tree'])))
        deployed = dict(source,testId=test_id,executableSHA256=adapter.sha((app/'Sill').read_bytes()),app=str(app))
        adapter.write(work/'deployment.json',deployed)
        normal = work/'normal68.json'
        adapter.write(normal,dict(build=68,source=source['commit'],tree=source['tree'],
            normalBundle=adapter.USER_BUNDLE,normalInstalled=True,installedVersionReadback=True,
            wholeProductAccepted=False))
        if failure == 'normal_source':
            value = adapter.read(normal); value['source']='0'*40; adapter.write(normal,value)
        methods = []; stopped = []; runtime_calls = []; clock = 1800000000
        selected = []; events = []
        def record(path, body):
            row = {'path':path,'status':200,'baseSha256':body['baseSha256'],
                   'textSha256':adapter.sha(body['text'].encode())}
            with (work/'review-note-writes.jsonl').open('a') as out: out.write(json.dumps(row)+'\n')
        def request(server, method, endpoint, body=None, **kwargs):
            path = urllib.parse.parse_qs(urllib.parse.urlsplit(endpoint).query)['path'][0]
            file = vault/path
            if method == 'PUT':
                self.assertEqual(body['baseSha256'],adapter.sha(file.read_bytes()) if file.exists() else None)
                file.write_bytes(body['text'].encode()); record(path,body)
            if not file.exists(): return 404, {}
            return 200,dict(path=path,text=file.read_bytes().decode(),sha256=adapter.sha(file.read_bytes()),
                            modifiedAt=adapter.sha(file.read_bytes()))
        def harness(config, target, method, variables, on_ready=None, **kwargs):
            nonlocal clock
            methods.append(method)
            path = variables['CCR_REVIEW_NOTE']; file=vault/path
            if method == 'testReviewSelectedGrade':
                selected.append(dict(variables))
                pairs = {'obsidianReviewAgain':(300,'5분'),'obsidianReviewHard':(600,'10분'),
                         'obsidianReviewGood':(86400,'24시간'),'obsidianReviewEasy':(172800,'48시간')}
                seconds, label = pairs[variables['CCR_REVIEW_GRADE_BUTTON_ID']]
                self.assertEqual(variables['CCR_REVIEW_GRADE_INTERVAL'],label)
                text=file.read_bytes().decode(); header=re.search(r'<!-- ccr-review-card:v1 (.*?) -->',text)
                metadata=json.loads(header[1]); event=str(uuid.uuid4()); events.append(event)
                hardcoded = failure == 'hardcoded_good' and corrupt_button in (None,variables['CCR_REVIEW_GRADE_BUTTON_ID'])
                metadata.update(eventID=event,ratedAt=clock,dueAt=clock+(86400 if hardcoded else seconds))
                if failure == 'metadata': metadata['foreign']='pollution'
                if failure == 'card_id': metadata['cardID']=str(uuid.uuid4())
                if failure == 'event_reused': metadata['eventID']=json.loads(header[1])['eventID']
                if failure == 'event_cross_grade' and len(events)>1: metadata['eventID']=events[0]
                if failure == 'timestamp': metadata.update(ratedAt=clock-1,dueAt=clock-1+seconds)
                if failure == 'boolean_time': metadata.update(ratedAt=True,dueAt=1+seconds)
                if failure == 'float_time': metadata.update(ratedAt=float(clock),dueAt=float(clock+seconds))
                if failure == 'interval': metadata['dueAt']+=1
                if failure != 'ui_only':
                    encoded=json.dumps(metadata,sort_keys=True,separators=(',',':'))
                    if failure == 'metadata_duplicate': encoded=encoded[:-1]+',"ratedAt":'+str(clock)+'}'
                    updated=text[:header.start(1)]+encoded+text[header.end(1):]
                    if failure == 'crlf': updated=updated.replace('\r\n','\n')
                    if failure == 'question': updated=updated.replace(variables['CCR_REVIEW_QUESTION'],'lost')
                    if failure == 'answer': updated=updated.replace(variables['CCR_REVIEW_ANSWER'],'lost')
                    body={'baseSha256':adapter.sha(file.read_bytes()),'text':updated}
                    request({},'PUT','/vault/note?path='+path,body)
                    if failure == 'duplicate_write': record(path,body)
                    if failure == 'audit_prefix':
                        audit=work/'review-note-writes.jsonl'; audit.write_text(audit.read_text().splitlines()[-1]+'\n')
            if method == 'testReviewReopen':
                self.assertEqual(stopped[-1],len(methods)-1)
                if failure == 'reopen_write':
                    record(path,{'baseSha256':adapter.sha(file.read_bytes()),'text':file.read_bytes().decode()})
            if method == 'testReviewLiveRemoteRevision':
                self.assertEqual(kwargs['ready_marker'],'CCR_REVIEW_LIVE_READY')
                if failure != 'missing_live': on_ready()
                if failure == 'live_extra_write':
                    record(path,{'baseSha256':adapter.sha(file.read_bytes()),'text':file.read_bytes().decode()})
            if failure == 'cross_fixture' and len(selected)==4:
                other=vault/selected[0]['CCR_REVIEW_NOTE']; other.write_bytes(b'changed later')
            clock += 1
            result=work/(str(len(methods))+'.xcresult')
            if failure != 'xcresult': result.mkdir()
            return result
        def runtime(config, target, id):
            runtime_calls.append(id)
            observed=dict(source,schema='ccr.ipad-test-runtime/v1',id=id,bundleID=adapter.BUNDLE,
                          executableSHA256=deployed['executableSHA256'])
            if failure == 'runtime_hash' or failure == 'runtime_post_hash' and len(runtime_calls)==2:
                observed['executableSHA256']='0'*64
            if failure == 'runtime_source': observed['tree']='0'*40
            evidence=work/('runtime-'+str(len(runtime_calls))+'.json'); adapter.write(evidence,observed)
            return observed,evidence
        def copy(config,target,source,destination,**kwargs):
            adapter.write(destination,{'id':test_id,'nodes':[{'text':'unrelated'}]})
        with patch.object(adapter,'lease'), patch.object(adapter,'request',side_effect=request), \
             patch.object(adapter,'harness',side_effect=harness), patch.object(adapter,'runtime_readback',side_effect=runtime), \
             patch.object(adapter,'copy_file',side_effect=copy), patch.object(adapter,'stop_owned',side_effect=lambda *a:stopped.append(len(methods))), \
             patch.object(adapter.time,'time',side_effect=lambda:clock), \
             patch.object(adapter,'command',side_effect=AssertionError('오프라인 검사에서 외부 명령 금지')), \
             patch.object(adapter.urllib.request,'urlopen',side_effect=AssertionError('오프라인 검사에서 네트워크 금지')):
            proof=adapter.accept_review_grades({},work,{},vault,test_id,normal)
        return proof,selected,methods,runtime_calls

    def test_four_grades_have_independent_metadata_wire_and_final_digests(self):
        with tempfile.TemporaryDirectory() as directory:
            proof,selected,methods,runtimes=self.exercise(directory)
            self.assertEqual([r['grade'] for r in proof['grades']],['again','hard','good','easy'])
            self.assertEqual([r['metadata']['dueAt']-r['metadata']['ratedAt'] for r in proof['grades']],[300,600,86400,172800])
            self.assertEqual(len({r['path'] for r in proof['grades']}),4)
            self.assertEqual(len({r['metadata']['cardID'] for r in proof['grades']}),4)
            self.assertEqual(len({r['metadata']['eventID'] for r in proof['grades']}),4)
            self.assertEqual(methods,['testReviewSelectedGrade','testReviewReopen','testReviewLiveRemoteRevision','testReviewReopen']*4)
            self.assertEqual(len(runtimes),2)
            self.assertEqual(len(selected),4)
            for row in proof['grades']:
                self.assertEqual(row['finalSha256'],adapter.sha((Path(directory)/'isolated-vault'/row['path']).read_bytes()))
                self.assertEqual(len(row['gradeRequests']),1)
                self.assertEqual(row['additionalRatingWrites'],0)
            self.assertFalse(proof['normalAppAccepted'])
            self.assertFalse(proof['fullAdapterAccepted'])

    def test_good_hardcoding_is_rejected_for_each_other_grade(self):
        for grade,button in [('again','obsidianReviewAgain'),('hard','obsidianReviewHard'),('easy','obsidianReviewEasy')]:
            with self.subTest(grade=grade), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(adapter.Held,'review_selected_grade_interval_or_time_invalid:'+grade):
                    self.exercise(directory,'hardcoded_good',button)
        with tempfile.TemporaryDirectory() as directory:
            proof,_,_,_=self.exercise(directory,'hardcoded_good','obsidianReviewGood')
            self.assertEqual(len(proof['grades']),4)

    def test_four_grades_reject_good_hardcoding_and_corrupt_effects(self):
        failures=['hardcoded_good','duplicate_write','metadata','metadata_duplicate','timestamp','crlf','interval',
                  'card_id','event_reused','event_cross_grade','boolean_time','float_time','ui_only',
                  'question','answer','reopen_write','live_extra_write','missing_live','audit_prefix',
                  'cross_fixture','xcresult','normal_source','runtime_hash','runtime_post_hash','runtime_source']
        for failure in failures:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises((adapter.Held,ValueError)):
                    self.exercise(directory,failure)
                self.assertFalse((Path(directory)/'review-four-grades-readback.json').exists())

    def test_grade_environment_is_exact_in_binary_xctestrun(self):
        import plistlib
        expected=[('obsidianReviewAgain','5분'),('obsidianReviewHard','10분'),
                  ('obsidianReviewGood','24시간'),('obsidianReviewEasy','48시간')]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); run=root/'HarnessDerivedData/Build/Products/test.xctestrun'
            run.parent.mkdir(parents=True)
            run.write_bytes(plistlib.dumps({'CanvasBridgeUITests':{'IsUITestBundle':True,'EnvironmentVariables':{
                'CCR_REVIEW_GRADE_BUTTON_ID':'stale','CCR_REVIEW_FOREIGN':'pollution','UNRELATED':'preserved'}}},
                fmt=plistlib.FMT_BINARY))
            adapter.write(root/'deployment.json',{'testId':str(uuid.uuid4()),'bundleIdentifier':adapter.USER_BUNDLE,'configuration':'Debug','sourceReadbackVerified':True})
            existing_runner_fixture(root,run)
            for button,label in expected:
                variables={'CCR_REVIEW_GRADE_BUTTON_ID':button,'CCR_REVIEW_GRADE_INTERVAL':label,
                           'CCR_REVIEW_DRAFT':'바깥\r\ne\u0301 👩🏽‍💻\r\n'}
                with patch.object(adapter,'prepared_runtime',return_value=adapter.read(root/'deployment.json')), \
                     patch.object(adapter,'verified_runner',return_value=adapter.read(root/'existing-runner.json')), patch.object(adapter,'lease'), patch.object(adapter,'command') as command, \
                     patch.object(adapter,'actual_xcresult') as actual:
                    result=adapter.harness(existing_runner_fixture(root,run),root,'testReviewSelectedGrade',variables)
                self.assertTrue((root/'ExistingRunner.xctestrun').read_bytes().startswith(b'bplist00'))
                loaded=plistlib.loads((root/'ExistingRunner.xctestrun').read_bytes())['CanvasBridgeUITests']['EnvironmentVariables']
                self.assertNotIn('CCR_REVIEW_FOREIGN',loaded)
                self.assertEqual(loaded['UNRELATED'],'preserved')
                for name,value in variables.items(): self.assertEqual(loaded[name].encode(),value.encode())
                self.assertIn('-only-testing:CanvasBridgeUITests/CanvasBridgeUITests/testReviewSelectedGrade',command.call_args.args[0])
                actual.assert_called_once_with(result,'testReviewSelectedGrade')

if __name__ == '__main__':
    unittest.main()

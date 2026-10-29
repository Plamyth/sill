import datetime,fcntl,hashlib,json,os,shutil,socket,subprocess,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[2];manifest=json.loads((root/'INPUTS.json').read_text());out=root/'output';out.mkdir();runtime=out/'runtime';runtime.mkdir()
life=Path.home()/'.local/bin/bt-service-lifecycle';owner=manifest['owner'];service_id='ccr-ipad-vault-pair-once-'+owner[-8:];node=Path.home()/'.local/bin/node'
def hashes():return {x['path']:hashlib.sha256((root/x['path']).read_bytes()).hexdigest() for x in manifest['files']}
def gone(pid):
 try:os.kill(pid,0);return False
 except ProcessLookupError:return True
report={'schema':'ccr.document-source-http-checks/v1','host':socket.gethostname(),'inputs':manifest,'sourceBefore':hashes(),'passed':False,'cleanupVerified':False};lease=None
try:
 assert report['sourceBefore']=={x['path']:x['sha256'] for x in manifest['files']}
 if manifest.get('verificationScope')=='document-delta':report['regression']={'executed':False,'reason':'문서 경계만 변경되어 기존 82ad9e7142fd의 전체 회귀와 분리하고 문서 파일/HTTP 경계를 검사한다. 이전 통과를 새 전체 회귀로 표시하지 않는다.'}
 for mode in (['documents'] if manifest.get('verificationScope')=='document-delta' else ['documents','regression']):
  cmd=['python3','CanvasRelay/run-checks.py','--output',str(out/mode)]+(['--documents'] if mode=='documents' else [])
  p=subprocess.Popen(cmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  try:stdout,stderr=p.communicate(timeout=180)
  except subprocess.TimeoutExpired:p.kill();stdout,stderr=p.communicate();raise
  report[mode]={'pid':p.pid,'pidGone':gone(p.pid),'exitCode':p.returncode,'result':json.loads(stdout),'stderr':stderr.decode(errors='replace')}
  if p.returncode:report[mode]['TAP']=(out/mode/'tests.tap').read_text();raise RuntimeError(mode+' failed')
 status=subprocess.run([life,'status'],capture_output=True,text=True);assert status.returncode in [0,2];before=json.loads(status.stdout);assert not [r for r in before['leases'] if r.get('serviceId')==service_id]
 report['ownLeaseBefore']=[];report['unrelatedLifecycleViolations']=len(before['violations'])
 cfg=json.loads((Path.home()/'.config/service-lifecycle/services.json').read_text());entry=next(x for x in cfg['services'] if x['id']==service_id);assert entry['lifecycle']=='leased' and entry['maxTtlSeconds']>=600
 settings={'token':uuid.uuid4().hex,'owner':owner,'ttlSeconds':600};(runtime/'settings.json').write_text(json.dumps(settings));(runtime/'settings.json').chmod(0o600)
 cmd=[str(life),'start',service_id,'--owner',owner,'--ttl','600','--generation',manifest['commit'],'--stdout',str(out/'node.out.log'),'--stderr',str(out/'node.err.log'),'--',str(node),str(root/'Tests/relay-document-pair/http.cjs'),str(runtime)]
 start=subprocess.run(cmd,capture_output=True,text=True);assert start.returncode==0,start.stderr
 lease=next(json.loads(p.read_text()) for p in (Path.home()/'.local/state/service-lifecycle/leases').glob('*.json') if json.loads(p.read_text()).get('serviceId')==service_id)
 assert lease['owner']==owner and lease['generation']==manifest['commit'];report['lease']=lease
 for _ in range(200):
  if (runtime/'ready.json').exists():break
  time.sleep(.05)
 ready=json.loads((runtime/'ready.json').read_text());assert ready['pid']==lease['pid'] and ready['port'] not in [8791,8793];report['listener']=ready
 (runtime/'go').write_text('run actual fixture HTTP')
 for _ in range(3000):
  if (runtime/'result.json').exists():break
  time.sleep(.1)
 result=json.loads((runtime/'result.json').read_text());report['HTTP']=result;assert result['passed'],result.get('error')
 report['passed']=True
except Exception as error:report['error']=str(error)
finally:
 if lease:
  release=subprocess.run([str(life),'release',lease['leaseId'],'--owner',owner],capture_output=True,text=True)
  report['release']={'exitCode':release.returncode,'result':release.stdout,'stderr':release.stderr}
  report['cleanupVerified']=release.returncode==0 and gone(lease['pid']) and not (Path.home()/'.local/state/service-lifecycle/leases'/(lease['leaseId']+'.json')).exists()
 else:report['cleanupVerified']=True
 report['sourceAfter']=hashes();report['sourceUnchanged']=report['sourceBefore']==report['sourceAfter'];report['passed']=report['passed'] and report['cleanupVerified'] and report['sourceUnchanged']
 for name in ['node.out.log','node.err.log']:
  p=out/name
  if p.exists():report[name]=p.read_text(errors='replace')[-10000:]
 report['actual8791']=report['actual8793']=report['HostDeviceUI']=report['externalDelivery']=0
 print(json.dumps(report,ensure_ascii=False))
raise SystemExit(0 if report['passed'] else 1)

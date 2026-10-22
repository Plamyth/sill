from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess,tempfile,json,os
root=Path.cwd()
with tempfile.TemporaryDirectory(prefix='peer-regressions-') as scratch:
 out=Path(scratch)
 env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
 checks=[('session',['python3','Tests/checks/peer-stream-session/run.py']),
 ('protocol',['python3','Tests/checks/source-intent/run.py','--suite','protocol']),
 ('source',['python3','Tests/checks/source-intent/run.py']),
 ('topology',['python3','Tests/checks/source-intent/run.py','--suite','topology']),
 ('publication',['python3','Tests/checks/source-intent/run.py','--suite','publication']),
 ('gesture',['python3','Tests/checks/gesture-drain-scope/run.py','--run']),
 ('monitor',['bash','Tests/checks/monitor-selection/run.sh']),
 ('pointer',['bash','Tests/checks/pointer-watch/run.sh']),
 ('menu',['bash','Tests/checks/menus/run.sh'])]
 def run(item):
  name,args=item
  p=subprocess.run(args,cwd=root,env=env,capture_output=True,text=True)
  print('PEER_CHECK '+json.dumps({'name':name,'exitCode':p.returncode,'output':(p.stdout+p.stderr)[-18000:]}),flush=True)
  return p.returncode
 with ThreadPoolExecutor(max_workers=len(checks)) as pool:codes=list(pool.map(run,checks))
 raise SystemExit(0 if all(x==0 for x in codes) else 1)

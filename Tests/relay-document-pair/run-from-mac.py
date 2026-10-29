import argparse,hashlib,json,os,runpy,subprocess
from pathlib import Path
options=argparse.ArgumentParser();options.add_argument('--document-delta',action='store_true');options=options.parse_args()
repo=Path(__file__).resolve().parents[2];evidence=repo.parent/'evidence';head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip();assert not subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True)
stage=evidence/('input-'+head[:12]);assert not stage.exists();stage.mkdir();rows=[]
for prefix in ['CanvasRelay','Tests/relay-document-pair']:
 for name in subprocess.check_output(['git','ls-tree','-r','--name-only',head,'--',prefix],cwd=repo,text=True).splitlines():
  data=subprocess.check_output(['git','show',head+':'+name],cwd=repo);p=stage/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);rows.append({'path':name,'sha256':hashlib.sha256(data).hexdigest()})
manifest={'commit':head,'base':'9006908998dbcbe0b278b3dc75c71d5d2006342a','files':rows,'owner':'01a18338-6fac-7582-8c4b-088a21a5098b','sourceGuardTransferAccepted':False,'verificationScope':'document-delta' if options.document_delta else 'full'};(stage/'INPUTS.json').write_text(json.dumps(manifest))
tool='/Users/ambrion/.local/bin/mini-ephemeral-source';digest=runpy.run_path(tool)['tree_digest'];before=digest(stage)
cmd=[tool,'run','--source',str(stage),'--owner',manifest['owner'],'--job','ipad-document-source','--max-age-seconds','1800','--','python3','Tests/relay-document-pair/run-mini.py']
with (evidence/('mini-result-'+head[:12]+'.json')).open('wb') as out,(evidence/('mini-wrapper-'+head[:12]+'.log')).open('wb') as err:r=subprocess.run(cmd,stdout=out,stderr=err)
assert digest(stage)==before
wrappers=[]
for line in (evidence/('mini-wrapper-'+head[:12]+'.log')).read_text().splitlines():
 try:x=json.loads(line)
 except ValueError:continue
 if isinstance(x,dict) and 'cleanup_verified'in x:wrappers.append(x)
assert wrappers and wrappers[-1]['cleanup_verified']
record={'commit':head,'tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=repo,text=True).strip(),'sourceUnchanged':True,'inputDigest':before,'wrapper':wrappers[-1],'exitCode':r.returncode}
(evidence/('orchestration-'+head[:12]+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
raise SystemExit(r.returncode)

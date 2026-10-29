#!/usr/bin/env python3
"""R1/R2 original bytes plus narrow native failure preservation; no whole suite/SDK."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, uuid, zipfile

p=argparse.ArgumentParser()
p.add_argument('--review-input',type=Path,required=True)
p.add_argument('--protocol-input',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path'])
assert a.output.resolve().is_relative_to(archive.resolve())
out=a.output/('repair-p2-'+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['fixtures','home','tmp']:(out/n).mkdir()
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
pinned={'hidden-xhtml':'27687897a4f2f26cb4862cbc8fa72085848204231a9bec133610661cbc0e3310','hidden-dat':'3ad747ab7b8dce313a6b54f6d999888d09120b6395bdce6e3af3057076916eef','ncx-exact':'45405f26e002da0a646396056af3a8599d1cc14bfa4b01a9be0bc90244a26cdf','ncx-alias':'202a6b5651608e58129343558485e549e3bfd4f0a2898b501ec917ec52c787e9'}
originals=[a.review_input/'fixtures'/(n+'.epub') for n in pinned]
for src in originals:
 assert sha(src)==pinned[src.stem]
 (out/'fixtures'/src.name).write_bytes(src.read_bytes())
def variant(source,name,edits):
 with zipfile.ZipFile(out/'fixtures'/(source+'.epub')) as z: items={i.filename:z.read(i) for i in z.infolist()}
 for path,(old,new) in edits.items():
  assert old in items[path]
  items[path]=items[path].replace(old,new)
 with zipfile.ZipFile(out/'fixtures'/(name+'.epub'),'w') as z:
  for path,data in items.items():
   info=zipfile.ZipInfo(path,date_time=(2026,10,29,0,0,0))
   info.compress_type=zipfile.ZIP_STORED if path=='mimetype' else zipfile.ZIP_DEFLATED
   z.writestr(info,data)
variant('hidden-dat','hidden-only-dat',{'OEBPS/one.dat':(b' style="display:none"',b'')})
variant('hidden-dat','style-only-dat',{'OEBPS/one.dat':(b' hidden="hidden"',b'')})
variant('hidden-dat','visible-dat',{'OEBPS/one.dat':(b' style="display:none" hidden="hidden"',b'')})
variant('ncx-alias','ncx-exact-nfd',{'OEBPS/one.xhtml':('id="é"'.encode(),'id="e\u0301"'.encode())})
variant('ncx-exact-nfd','ncx-reverse-alias',{'OEBPS/toc.ncx':('#e\u0301'.encode(),'#é'.encode())})
root=Path(__file__).resolve().parents[3]
sources=[root/'iOSClient/CanvasBridge'/(n+'.swift') for n in ['CanvasModel','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']]
inputs=sources+[Path(__file__),Path(__file__).with_suffix('.swift'),a.protocol_input/'StreamProtocol.o',a.protocol_input/'StreamProtocol.swiftmodule']
assert sha(inputs[-2])=='4c1423636939dec8983848616299dbef168f0edf75c99f9276bfe1e9d6045c4f'
assert sha(inputs[-1])=='b3e42a4f6594aa4879288aeaf50b3290dad9cdd0383cb0eda961f0661b95e34b'
hashes=lambda paths:{str(x):sha(x) for x in paths}
before=hashes(inputs+originals+list((out/'fixtures').iterdir()))
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
cmd=['xcrun','swiftc','-D','DEBUG','-swift-version','5','-sdk',sdk,'-target','arm64e-apple-macos27.0','-module-cache-path',str(out/'modules'),'-parse-as-library','-I',str(a.protocol_input),*map(str,sources),str(Path(__file__).with_suffix('.swift')),str(inputs[-2]),'-o',str(out/'check')]
results=[]
for name,argv in [('compile',cmd),('native',[str(out/'check'),str(out)])]:
 run=subprocess.run(argv,cwd=root,env=env,capture_output=True,text=True,timeout=120)
 (out/(name+'.log')).write_text(run.stdout+run.stderr)
 results.append({'phase':name,'argv':argv,'exit':run.returncode})
 print(name,run.returncode,(run.stdout+run.stderr)[-3000:],flush=True)
 if run.returncode:break
after=hashes(inputs+originals+list((out/'fixtures').iterdir()))
record={'baseCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'inputBefore':before,'inputAfter':after,'sourceAndOriginalsUnchanged':before==after,'phases':results,'passed':len(results)==2 and all(x['exit']==0 for x in results) and before==after,'whole44Repeated':False,'iOSSDKRepeated':False,'GUI':False,'device':False,'Host':False,'installation':False}
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print('RECEIPT',out/'result.json')
raise SystemExit(0 if record['passed'] else 1)

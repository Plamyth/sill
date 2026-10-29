#!/usr/bin/env python3
"""Native EPUB/Files checks; fixtures stay in the approved SSD output directory."""
from pathlib import Path
import argparse,hashlib,json,os,struct,subprocess,uuid,zipfile
from io import BytesIO

p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--rea-input',type=Path);a=p.parse_args()
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path'])
assert a.output.resolve().is_relative_to(archive.resolve())
out=a.output/('native-'+str(uuid.uuid4()));out.mkdir(parents=True)
root=Path(__file__).resolve().parents[3]
for n in ['home','tmp','rejected']:(out/n).mkdir()
container=b'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>'
opf=b'<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>'
def chapter(word):return ('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>'+word+'</title></head><body><h1>'+word+'</h1><p id="anchor">앞말 😀 가나다 EPUB Anchor '+word+' 끝말.</p></body></html>').encode()
ncx=b'<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="one"><navLabel><text>Alpha</text></navLabel><content src="one.xhtml"/></navPoint><navPoint id="two"><navLabel><text>Beta</text></navLabel><content src="two.xhtml"/></navPoint></navMap></ncx>'
entries={'mimetype':b'application/epub+zip','META-INF/container.xml':container,'OEBPS/book.opf':opf,'OEBPS/one.xhtml':chapter('Alpha'),'OEBPS/two.xhtml':chapter('Beta'),'OEBPS/toc.ncx':ncx}
def packed(items,extra=[]):
 data=BytesIO()
 with zipfile.ZipFile(data,'w') as z:
  for name,value in list(items.items())+extra:z.writestr(name,value,compress_type=zipfile.ZIP_STORED if name=='mimetype' else zipfile.ZIP_DEFLATED)
 return data.getvalue()
normal=packed(entries);(out/'normal.epub').write_bytes(normal)
changed=dict(entries);changed['OEBPS/one.xhtml']=chapter('Alpha changed');(out/'changed.epub').write_bytes(packed(changed))
def reject(name,items=None,extra=[],data=None):(out/'rejected'/name).write_bytes(data if data is not None else packed(items or entries,extra))
for name,path in [('zip-slip','../escape'),('absolute','/escape'),('backslash','OEBPS\\escape'),('dot-path','OEBPS/./escape')]:reject(name,extra=[(path,b'own')])
reject('duplicate',extra=[('OEBPS/one.xhtml',chapter('Alpha'))])
reject('normalized',extra=[('OEBPS/e\u0301.xhtml',b'own')])
reject('drm',extra=[('META-INF/encryption.xml',b'<encryption/>')])
reject('script',extra=[('OEBPS/unused.xhtml',b'<html><script>never execute</script></html>')])
reject('external-entity',extra=[('OEBPS/unused.xml',b'<!DOCTYPE x [<!ENTITY x SYSTEM "file:///etc/passwd">]><x>&x;</x>')])
reject('remote-resource',extra=[('OEBPS/unused.xhtml',b'<html><img src="https://example.invalid/private"/></html>')])
reject('css-network',extra=[('OEBPS/unused.css',b'@import "https://example.invalid";')])
bad=dict(entries);bad['OEBPS/one.xhtml']=chapter('Alpha').replace(b'<p id="anchor">',b'<p id="anchor" style="display:none">');reject('hidden-css-text',bad)
reject('xml-attribute-limit',extra=[('OEBPS/unused.xml',('<x '+' '.join('a'+str(i)+'="v"' for i in range(65))+'/>').encode())])
reject('bomb-ratio',extra=[('OEBPS/bomb.bin',b'A'*200000)])
reject('entry-too-large',extra=[('OEBPS/large.bin',b'A'*(4*1024*1024+1))])
bad=dict(entries);bad['OEBPS/book.opf']=opf.replace(b'id="two"',b'id="one"');reject('duplicate-opf-id',bad)
bad=dict(entries);bad['OEBPS/toc.ncx']=ncx.replace(b'two.xhtml',b'two.xhtml#missing');reject('bad-ncx',bad)
raw=bytearray(normal);central=raw.find(b'PK\x01\x02');raw[6]|=1;raw[central+8]|=1;reject('encrypted',data=bytes(raw))
raw=bytearray(normal);raw[30]=ord('X');reject('local-central-alias',data=bytes(raw))
raw=bytearray(normal);raw[14]^=1;raw[raw.find(b'PK\x01\x02')+16]^=1;reject('crc-corrupt',data=bytes(raw))
reject('trailing-data',data=normal+b'not an archive comment')
raw=bytearray(packed(entries,[('OEBPS/bomb.bin',b'A'*200000)]))
with zipfile.ZipFile(BytesIO(raw)) as z:local=z.getinfo('OEBPS/bomb.bin').header_offset
at=raw.find(b'PK\x01\x02')
while at>=0:
 n,e,c=struct.unpack_from('<HHH',raw,at+28)
 if raw[at+46:at+46+n]==b'OEBPS/bomb.bin':struct.pack_into('<I',raw,at+24,16);break
 at+=46+n+e+c
struct.pack_into('<I',raw,local+22,16);reject('deflate-over-declared-size',data=bytes(raw))
raw=BytesIO()
with zipfile.ZipFile(raw,'w') as z:
 for name,value in entries.items():z.writestr(name,value)
 info=zipfile.ZipInfo('OEBPS/link');info.create_system=3;info.external_attr=0o120777<<16;z.writestr(info,'elsewhere')
reject('symlink-entry',data=raw.getvalue())
bad=dict(entries);bad['OEBPS/one.xhtml']=chapter('Alpha').replace(b'http://www.w3.org/1999/xhtml',b'urn:unsupported');reject('foreign-xhtml-namespace',bad)
sources=[root/'iOSClient/CanvasBridge'/(n+'.swift') for n in ['CanvasModel','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']]
protocol=root/'Sources/StreamProtocol/TestDestinations.swift';main=Path(__file__).with_name('main.swift')
inputs=sources+[protocol,main,Path(__file__),root/'iOSClient/Sill.xcodeproj/project.pbxproj']
hashes=lambda:{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
before=hashes();env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-D','DEBUG','-swift-version','5','-sdk',sdk,'-target','arm64e-apple-macos27.0','-module-cache-path',str(out/'modules')]
commands=[('protocol',base+['-parse-as-library','-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol',str(protocol),'-emit-module-path',str(out/'StreamProtocol.swiftmodule'),'-o',str(out/'StreamProtocol.o')]),('compile',base+['-parse-as-library','-I',str(out),*map(str,sources),str(main),str(out/'StreamProtocol.o'),'-o',str(out/'check')]),('native',[str(out/'check'),str(out)]),('project',['plutil','-lint',str(inputs[-1])])]
rea_sha=None
if a.rea_input:
 rea_sha=hashlib.sha256(a.rea_input.read_bytes()).hexdigest()
 (out/'rea').mkdir();(out/'rea/normal.epub').write_bytes(a.rea_input.read_bytes())
 commands += [('native-rea-archive',[str(out/'check'),str(out/'rea'),'--rea-archive'])]
ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
ib=['xcrun','swiftc','-D','DEBUG','-swift-version','5','-sdk',ios,'-target','arm64-apple-ios27.0','-module-cache-path',str(out/'ios-modules')]
commands += [('ios-protocol',ib+['-emit-module','-module-name','StreamProtocol',str(protocol),'-emit-module-path',str(out/'ios/StreamProtocol.swiftmodule')]),('ios27',ib+['-parse-as-library','-I',str(out/'ios'),'-typecheck',*map(str,sources)])]
(out/'ios').mkdir();results=[]
for name,cmd in commands:
 run=subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,timeout=180)
 (out/(name+'.log')).write_text(run.stdout+run.stderr);print(name,run.returncode,(run.stdout+run.stderr)[-4500:],flush=True)
 results.append(dict(name=name,exitCode=run.returncode,command=cmd))
 if run.returncode:break
after=hashes();rea_unchanged=not a.rea_input or hashlib.sha256(a.rea_input.read_bytes()).hexdigest()==rea_sha
record=dict(sourceBefore=before,sourceAfter=after,sourceUnchanged=before==after,results=results,passed=len(results)==len(commands) and all(x['exitCode']==0 for x in results) and before==after and rea_unchanged,reaSourceSHA256=rea_sha,reaSourceUnchanged=rea_unchanged,HTTP=False,GUI=False,device=False,installation=False,output=str(out))
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('RECEIPT',out/'result.json')
raise SystemExit(0 if record['passed'] else 1)

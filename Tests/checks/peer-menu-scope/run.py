from pathlib import Path
import argparse,hashlib,json,os,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--mini',action='store_true');parser.add_argument('--archive',type=Path);args=parser.parse_args()
def block(text, marker):
 start=text.index(marker);end=text.index('{',start)+1;depth=1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
paths=sorted((root/'Sources/StreamProtocol').glob('*.swift'))+[root/'Sources/SillHost'/name for name in ['StreamServer.swift','SentryAdmission.swift','PeerInputQueue.swift','MenuMirror.swift','MenuFormat.swift','MenuPolicy.swift','StreamCoordinator.swift']]+[here/name for name in ['Fixture.swift','main.swift','run.py']]
hashes={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
server=(root/'Sources/SillHost/StreamServer.swift').read_text()
coordinator=(root/'Sources/SillHost/StreamCoordinator.swift').read_text()
helpers='import Foundation\nimport StreamProtocol\n'+server[server.index('final class SourcePublicationAdmission:'):server.index('/// Advertises _sill._tcp')]
helpers+='\n'+(root/'Sources/SillHost/SentryAdmission.swift').read_text()+'\n'+(root/'Sources/SillHost/PeerInputQueue.swift').read_text()
fixture=(here/'Fixture.swift').read_text().replace('__EXECUTE_PRESS__',block(coordinator,'mirror.executePress = {')).replace('__REVOKE_PRESS__',block(coordinator,'for id in self.connections.keys where !self.server.sentryAdmission.allowsActions(id) {'))
program='\n'.join([helpers,(root/'Sources/SillHost/MenuMirror.swift').read_text().replace('private ',''),(root/'Sources/SillHost/MenuFormat.swift').read_text(),(root/'Sources/SillHost/MenuPolicy.swift').read_text(),fixture,(here/'main.swift').read_text()])
protocol='\n'.join(p.read_text() for p in sorted((root/'Sources/StreamProtocol').glob('*.swift')))
if args.mini:
 assert args.archive is not None and not args.archive.exists()
 blob=json.dumps(dict(protocol=protocol,program=program)).encode()
 remote='''import hashlib,json,pathlib,subprocess,sys,tempfile
blob=sys.stdin.buffer.read();received=hashlib.sha256(blob).hexdigest();source=json.loads(blob);del blob
records=[];code=0
with tempfile.TemporaryDirectory(prefix='menu-scope-01a13005-') as folder:
 out=pathlib.Path(folder)
 flags=['xcrun','swiftc','-swift-version','5','-package-name','Sill','-parse-as-library','-module-cache-path',str(out/'cache')]
 commands=[('protocol-module',flags+['-whole-module-optimization','-emit-module','-module-name','StreamProtocol','-emit-module-path',str(out/'StreamProtocol.swiftmodule'),'-'],source['protocol']),('protocol-object',flags+['-whole-module-optimization','-emit-object','-module-name','StreamProtocol','-o',str(out/'StreamProtocol.o'),'-'],source['protocol']),('menu',flags+['-I',folder,str(out/'StreamProtocol.o'),'-o',str(out/'checks'),'-'],source['program']),('checks',[str(out/'checks')],None)]
 for name,command,text in commands:
  result=subprocess.run(command,input=text,text=True,capture_output=True,timeout=180 if name!='checks' else 30)
  print(result.stdout+result.stderr,end='',flush=True);records.append(dict(name=name,exitCode=result.returncode))
  if result.returncode:code=result.returncode if result.returncode>0 else 128-result.returncode;break
 del source
print('MENU_RESULT '+json.dumps(dict(receivedSHA256=received,commands=records,temporaryFilesRemoved=not out.exists(),RAMSourceReleased=True,actualAXPress=0,visibleWindows=0,hostSignals=0,authenticationRequests=0)),flush=True)
raise SystemExit(code)
'''
 result=subprocess.run(['/Users/ambrion/.local/bin/mini','run','--cwd','/Users/sin-wonho','--','python3','-B','-c',remote],input=blob,capture_output=True,timeout=420)
 output=result.stdout.decode(errors='replace')+result.stderr.decode(errors='replace')
 args.archive.with_suffix('.log').write_text(output)
 summary=next((json.loads(line.removeprefix('MENU_RESULT ')) for line in output.splitlines() if line.startswith('MENU_RESULT ')),None)
 record=dict(sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sourceSHA256=hashes,sentSHA256=hashlib.sha256(blob).hexdigest(),remote=summary,exitCode=result.returncode,sourceUnchanged=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==sha for p,sha in hashes.items()),scope='Mini RAM 입력과 실제 메뉴·publication·큐 본문 및 격리 AX 어댑터. 기기·네이티브 AX 실행 수용 아님.')
 args.archive.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({k:record[k] for k in ['exitCode','sourceUnchanged','remote']},ensure_ascii=False))
 raise SystemExit(result.returncode if record['sourceUnchanged'] else 2)
with tempfile.TemporaryDirectory(prefix='peer-menu-') as tmp:
 out=Path(tmp)
 def run(command):subprocess.run(command,cwd=out,check=True)
 run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-emit-library','-emit-module','-module-name','StreamProtocol',*map(str,(root/'Sources/StreamProtocol').glob('*.swift')),'-o',str(out/'libStreamProtocol.dylib')])
 (out/'Program.swift').write_text(program)
 run(['xcrun','swiftc','-swift-version','5','-package-name','Sill','-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),str(out/'Program.swift'),'-o',str(out/'checks')])
 run([str(out/'checks')])

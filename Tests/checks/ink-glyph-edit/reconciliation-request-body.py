#!/usr/bin/env python3
"""Compile the exact product request DTO and encoder expression; no Model/GUI/network/provider."""
from pathlib import Path
import argparse,subprocess,json,os,uuid,hashlib
root=Path(__file__).resolve().parents[3];source=root/'iOSClient/CanvasBridge/CanvasRelay.swift'
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);args=p.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(x.exists() and os.path.samefile(x,route['path']) for x in [args.output,*args.output.parents])
args.output.mkdir(parents=True,exist_ok=True)
out=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())/('request-body-'+str(uuid.uuid4()));out.mkdir()
for name in ['home','tmp']:(out/name).mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
text=source.read_text();before=hashlib.sha256(source.read_bytes()).hexdigest()
def extract(marker):
 a=text.index(marker);i=text.index('{',a)+1;depth=1
 while depth:depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[a:i]
parts=[extract(m) for m in ['enum ConflictDecision:', 'struct ConflictExpected:', 'private struct ConflictRequest:']]
expression=next(line.strip() for line in text.splitlines() if 'let body = try JSONEncoder().encode(ConflictRequest(' in line)
swift='import Foundation\nenum ActualRequestCheck {\n'+'\n'.join(parts)+'''
struct Context {let recoveryID:UUID;let expected:ConflictExpected}
static func run() throws {
 let canonical="74cc01fd-c55a-4511-b0a9-5bbd489ea384"
 let expected=try JSONDecoder().decode(ConflictExpected.self,from:Data(("{\\"activeSha256\\":null,\\"baseSha256\\":null,\\"displacedSha256\\":null,\\"proposalSha256\\":null,\\"historySha256\\":\\""+String(repeating:"a",count:64)+"\\"}").utf8))
 let conflict=Context(recoveryID:UUID(uuidString:canonical)!,expected:expected)
 precondition(conflict.recoveryID.uuidString != canonical,"reproduce Foundation uppercase UUID representation")
 for decision in ConflictDecision.allCases {
'''+expression+'''
  let value=try JSONSerialization.jsonObject(with:body) as! [String:Any]
  precondition(value["recoveryID"] as? String == canonical,"strict journal lookup requires exact lowercase JSON string")
  precondition(Set(value.keys)==Set(["recoveryID","expected","decision"]))
  let echoed=value["expected"] as! [String:Any]
  precondition(echoed.count==5 && echoed["activeSha256"] is NSNull && echoed["baseSha256"] is NSNull && echoed["displacedSha256"] is NSNull && echoed["proposalSha256"] is NSNull)
  precondition(value["decision"] as? String==decision.rawValue)
  print(String(data:body,encoding:.utf8)!)
 }
 print("REQUEST_BODY_OK canonical exact recoveryID both decisions; three request fields; five expected keys including null")
}
}
try ActualRequestCheck.run()
'''
(out/'check.swift').write_text(swift)
records=[]
commands=[('compile',['xcrun','swiftc','-swift-version','5','-module-cache-path',str(out/'modules'),str(out/'check.swift'),'-o',str(out/'check')]),('body',[str(out/'check')])]
for name,cmd in commands:
 r=subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,timeout=120);log=r.stdout+r.stderr
 (out/(name+'.log')).write_text(log);print(name,r.returncode,log[-6000:],flush=True)
 records.append(dict(name=name,exitCode=r.returncode,command=cmd))
 if r.returncode:break
record=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),productSHA256=before,productSHA256After=hashlib.sha256(source.read_bytes()).hexdigest(),exactExtractedEncoder=expression,exactExtractedDeclarationSHA256=[hashlib.sha256(s.encode()).hexdigest() for s in parts],output=str(out),results=records,passed=len(records)==2 and all(r['exitCode']==0 for r in records) and before==hashlib.sha256(source.read_bytes()).hexdigest(),actualHTTP=False,deviceHostEffects=0)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('REQUEST_BODY_OUTPUT',out)
raise SystemExit(0 if record['passed'] else 1)

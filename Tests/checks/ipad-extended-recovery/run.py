from pathlib import Path
import argparse,sys,subprocess,json,hashlib,datetime
here=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--module-cache", required=True)
args=parser.parse_args()
output=Path(args.output).resolve()
module_cache=Path(args.module_cache).resolve()
output.mkdir(parents=True,exist_ok=True)
root=here.parents[2];program=root/'Tests/checks/source-request/run.py'
sys.argv=[str(program),'--output',str(output)]
code=program.read_text().split('sha = lambda data:')[0]
code=code.replace("if not out.is_absolute() or out.exists():", "if not out.is_absolute():").replace('out.mkdir()', 'out.mkdir(exist_ok=True)')
namespace={'__file__':str(program)}
exec(compile(code,str(program),'exec'),namespace)
inputs=namespace['inputs'];inputs.pop('AutomaticDisplay.swift',None)
declaration=next(line.strip().replace('private ', '') for line in (root/'iOSClient/StreamClient.swift').read_text().splitlines() if 'private static let noAutoDesktop =' in line)
inputs['Client.swift']=inputs['Client.swift'].replace('static let noAutoDesktop = false',declaration)
inputs['Client.swift']=inputs['Client.swift'].replace('    var defaults = TestDefaults()', '    func sentryReturnTrustChanged() {}\n    var defaults = TestDefaults()')
inputs['Client.swift']='''import Foundation
struct UIApplication { enum State { case active, background }; static var shared = UIApplication(); var applicationState = State.active }
struct UIDevice { enum Idiom { case pad, phone }; static var current = UIDevice(); var userInterfaceIdiom = Idiom.pad }
'''+inputs['Client.swift']
inputs['SentryReturn.swift']=(root/'Sources/StreamProtocol/SentryReturn.swift').read_text()
inputs['main.swift']=(here/'main.swift').read_text()
out=output
for name,value in inputs.items():
 (out/name).write_text(value)
cmd=['/usr/bin/swiftc','-parse-as-library','-module-cache-path',str(module_cache)]+[str(out/n) for n in inputs if n.endswith('.swift')]+['-o',str(out/'suite')]
production=[root/'iOSClient/StreamClient.swift',root/'iOSClient/StreamClient+Viewport.swift',root/'iOSClient/SessionLink.swift',root/'iOSClient/StreamScreen.swift',root/'Tests/checks/ipad-extended-display/fixture.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in production}
compiled=subprocess.run(cmd)
result=subprocess.run([str(out/'suite'),'-SillNoAutoDesktop','YES'],capture_output=True,text=True) if compiled.returncode==0 else None
if result is not None: print(result.stdout,end='');print(result.stderr,end='',file=sys.stderr)
receipt={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'root':str(root),'sourceHashes':before,'sourceUnchanged':all(sha(root/p)==h for p,h in before.items()),'compileExit':compiled.returncode,'testExit':result.returncode if result else None,'testOutput':result.stdout if result else None,'scope':'actual product state-transition/selection methods and SessionLink; controlled NWConnection/UIKit and unrelated existing fixture boundaries; no physical device or server allocation'}
(out/'result.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
raise SystemExit(compiled.returncode or (result.returncode if result else 1))

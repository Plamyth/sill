"""실제 저장 연결 후보와 home 진입 메서드를 I/O 대역으로 실행한다."""
from pathlib import Path
import importlib.util,os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('startup_extractor',ROOT/'Tests/checks/vision-autoconnect/run.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
stream=(ROOT/'iOSClient/StreamClient.swift').read_text()
remote=(ROOT/'iOSClient/StreamClient+Remote.swift').read_text()
dial=m.block(remote,'func dialSaved(')
start=dial.index('let candidates = RemoteDialPolicy.')
end=dial.index('\n        #if DEBUG',start)
candidates=dial[start:end]
methods='\n'.join(m.vision(m.block(stream,marker)) for marker in ['func homeDecision(', 'func dialRow('])
move=m.block(stream,'func moveHomeIfListed()')
move=move[:move.index('        // Every network row')]+ '\n        homeEligible += 1\n    }'
start_move=m.block(stream,'private func startMove(')
start_move=start_move[:start_move.index('        let refused = WeakConnection()')].replace('private func','func')+'\n        moveCreated += 1\n    }'
fixture=(HERE/'Standins.swift').read_text().replace('/* ACTUAL_METHODS */',methods+'\n'+move+'\n'+start_move)
fixture=fixture.replace('/* ACTUAL_CANDIDATES */',candidates+'\n        return candidates')
fixture+='\n'+(HERE/'scenarios.swift').read_text()
with tempfile.TemporaryDirectory(prefix='owner-session-routing-') as folder:
 out=Path(folder);cache=out/'cache';env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(cache))
 subprocess.run(['swiftc','-module-cache-path',str(cache),'-emit-library','-emit-module','-module-name','StreamProtocol',*map(str,sorted((ROOT/'Sources/StreamProtocol').glob('*.swift'))),'-o',str(out/'libStreamProtocol.dylib')],check=True,env=env,timeout=180)
 (out/'main.swift').write_text(fixture)
 subprocess.run(['swiftc','-module-cache-path',str(cache),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),str(ROOT/'iOSClient/SavedMacs.swift'),str(ROOT/'iOSClient/RemoteDialPolicy.swift'),str(ROOT/'iOSClient/DiscoveryPolicy.swift'),str(out/'main.swift'),'-o',str(out/'checks')],check=True,env=env,timeout=180)
 subprocess.run([str(out/'checks')],check=True,timeout=30)

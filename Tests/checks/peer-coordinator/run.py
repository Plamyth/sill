from pathlib import Path
import subprocess,tempfile,os,json
root=Path(__file__).resolve().parents[3]
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',SILL_TEST_LOOPBACK='1')
with tempfile.TemporaryDirectory(prefix='peer-coordinator-') as temporary:
    scratch=Path(temporary)
    command=['swift','build','--build-system','native','-c','release','--target','SillHostCore','--scratch-path',str(scratch),
             '--cache-path',str(scratch/'cache'),'--config-path',str(scratch/'config'),'--security-path',str(scratch/'security'),
             '--manifest-cache','none','-Xswiftc','-enable-testing','-Xswiftc','-DPEER_STREAM_CONTRACT']
    subprocess.run(command,cwd=root,env=env,check=True)
    modules=next(scratch.glob('*/release/Modules')); out=modules.parent
    objects=sorted((out/'StreamProtocol.build').glob('*.o'))+sorted((out/'SillHostCore.build').glob('*.o'))+sorted((out/'AudioSilence.build').rglob('*.o'))
    description=json.loads((out/'description.json').read_text())
    args=next(c['otherArguments'] for c in description['swiftCommands'].values() if c['moduleName']=='SillHostCore')
    package=args[args.index('-package-name')+1]
    binary=scratch/'coordinator-checks'
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-package-name',package,'-I',str(modules),
                    '-Xcc','-fmodule-map-file='+str(out/'AudioSilence.build/module.modulemap'),str(Path(__file__).with_name('main.swift')),*map(str,objects),'-o',str(binary)],cwd=root,env=env,check=True)
    subprocess.run([str(binary)],cwd=root,env=env,check=True,timeout=35)
print(json.dumps({'scope':'actual coordinator and loopback server; fake capture, dry OS input; no physical proof','scratchRemoved':not scratch.exists()}))

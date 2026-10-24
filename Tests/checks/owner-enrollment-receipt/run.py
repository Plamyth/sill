from pathlib import Path
import argparse, subprocess, os, json, hashlib
p=argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); p.add_argument('--red',action='store_true'); p.add_argument('--sdk-developer-dir'); a=p.parse_args()
r=Path(__file__).resolve().parents[3]; out=a.output; out.mkdir(parents=True,exist_ok=True)
b=out/'build'; b.mkdir(exist_ok=True)
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
env={**os.environ,'SDKROOT':sdk,'CLANG_MODULE_CACHE_PATH':str(b/'cache'),'SWIFTPM_MODULECACHE_OVERRIDE':str(b/'cache'),'PYTHONDONTWRITEBYTECODE':'1'}
swift=['xcrun','swiftc','-swift-version','5','-package-name','Sill','-module-cache-path',str(b/'cache')]
protocol=sorted((r/'Sources/StreamProtocol').glob('*.swift'))
inputs=sorted((r/'Sources').rglob('*.swift'))+sorted(Path(__file__).parent.glob('*.swift'))
before={str(x.relative_to(r)):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
if a.red:
    subprocess.run(swift+['-emit-module','-module-name','StreamProtocol',*map(str,protocol),'-emit-module-path',str(b/'StreamProtocol.swiftmodule')],check=True)
    result=subprocess.run(swift+['-typecheck','-I',str(b),str(Path(__file__).with_name('Red.swift'))],capture_output=True,text=True)
    (out/'red.log').write_text(result.stdout+result.stderr)
    assert result.returncode!=0 and 'OwnerEnrollmentRequest' in result.stderr, 'RED must fail on missing receipt API'
    (out/'red.json').write_text(json.dumps({'expectedFailure':True,'returnCode':result.returncode,'reason':'missing receipt API'},indent=2)); print('RED expected missing receipt API'); raise SystemExit(0)
cmd=['swift','build','--build-system','native','-c','debug','--target','SillHostCore','--scratch-path',str(b/'spm'),'--cache-path',str(b/'spm-cache'),'--config-path',str(b/'spm-config'),'--security-path',str(b/'spm-security'),'--manifest-cache','none','-Xswiftc','-enable-testing','-Xswiftc','-DOWNER_BOOTSTRAP_CONTRACT']
subprocess.run(cmd,cwd=r,env=env,check=True)
modules=next((b/'spm').glob('*/debug/Modules')); output=modules.parent
objects=sorted((output/'StreamProtocol.build').glob('*.o'))+sorted((output/'SillHostCore.build').glob('*.o'))+sorted((output/'AudioSilence.build').glob('*.o'))
description=json.loads((output/'description.json').read_text()); arguments=next(c['otherArguments'] for c in description['swiftCommands'].values() if c['moduleName']=='SillHostCore'); package=arguments[arguments.index('-package-name')+1]
subprocess.run(swift+['-parse-as-library','-package-name',package,'-I',str(modules),'-I',str(output/'AudioSilence.build'),str(Path(__file__).with_name('Main.swift')),*map(str,objects),'-o',str(b/'checks')],cwd=r,env=env,check=True)
subprocess.run([str(b/'checks')],cwd=r,env=env,check=True,timeout=120)
subprocess.run(swift+['-parse-as-library','-package-name',package,'-I',str(modules),'-I',str(output/'AudioSilence.build'),str(r/'Tests/checks/owner-host-bootstrap/main.swift'),*map(str,objects),'-o',str(b/'owner-regressions')],cwd=r,env=env,check=True)
subprocess.run([str(b/'owner-regressions')],cwd=r,env=env,check=True)
results=[]
sdk_env={**os.environ}
if a.sdk_developer_dir: sdk_env['DEVELOPER_DIR']=a.sdk_developer_dir
for name,target in [('macosx','arm64-apple-macosx14.0'),('iphoneos','arm64-apple-ios17.0'),('xros','arm64-apple-xros2.5')]:
    path=subprocess.check_output(['xcrun','--sdk',name,'--show-sdk-path'],text=True,env=sdk_env).strip()
    subprocess.run(swift+['-typecheck','-sdk',path,'-target',target,'-module-name','StreamProtocol',*map(str,protocol)],cwd=r,env=sdk_env,check=True); results.append({'sdk':name,'target':target,'passed':True})
after={str(x.relative_to(r)):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}; assert before==after
(out/'verification.json').write_text(json.dumps({'before':before,'after':after,'sourceUnchanged':True,'sdks':results,'scope':'production HostCore; inert store/sensor/socket bindings only','runtimeAccepted':False,'keychainCalls':0,'networkConnections':0,'serviceChanges':0,'UIChanges':0},indent=2))
print('GREEN production HostCore and 3 StreamProtocol SDKs; effects=0')

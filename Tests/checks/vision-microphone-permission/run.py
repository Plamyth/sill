import hashlib,json,pathlib,re,subprocess,sys
root,output=map(lambda p:pathlib.Path(p).resolve(),sys.argv[1:3])
output.mkdir(parents=True,exist_ok=True)
base=['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(output/'cache')]
record={'scope':'Exact shared policy runtime, no native IO or device effects','commands':[],'exitCode':2}
def run(cmd,label):
 p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
 (output/(label+'.log')).write_text(p.stdout)
 record['commands'].append({'label':label,'exitCode':p.returncode})
 print(p.stdout[-4500:],flush=True)
 return p.returncode,p.stdout
try:
 protocol=sorted((root/'Sources/StreamProtocol').glob('*.swift'))
 code,log=run(base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name','StreamProtocol']+list(map(str,protocol))+['-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'StreamProtocol.o')],'protocol')
 if code:raise RuntimeError('protocol compile failed')
 fixture=root/'Tests/checks/vision-microphone-permission'
 source=root/'iOSClient/IPadMicrophonePolicy.swift'
 for name in ['repro','permission']:
  path=fixture/(name+'.swift')
  if not path.exists():continue
  main=output/'main.swift';main.write_bytes(path.read_bytes())
  code,log=run(base+['-I',str(output),str(source),str(main),str(output/'StreamProtocol.o'),'-o',str(output/name)],name+'-compile')
  if code:raise RuntimeError(name+' compilation failed')
  code,log=run([str(output/name)],name+'-runtime')
  if code:record['exitCode']=code;record['failure']=log.strip();break
  record[name]=log.strip()
 else:record['exitCode']=0
except Exception as error:record['error']=str(error)
(output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
print('SUITE_RESULT '+json.dumps(record),flush=True)
sys.exit(record['exitCode'])

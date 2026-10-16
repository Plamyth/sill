import ast, base64, hashlib, json, pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[3]
label=sys.argv[1]
out=pathlib.Path(__file__).resolve().parent/'receipts'
out.mkdir(exist_ok=True)
if (out/(label+'.json')).exists(): raise SystemExit('Reconcile existing attempt')
reference=root/'Tests/checks/reconnect-glue/mini.py'
module=ast.parse(reference.read_text())
runner=next(ast.literal_eval(node.value) for node in module.body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='runner' for t in node.targets))
paths={'VisionAudioState.swift':root/'visionOSClient/VisionAudioState.swift','main.swift':pathlib.Path(__file__).resolve().parent/'main.swift'}
if '--adapter' in sys.argv:
 paths['main.swift']=pathlib.Path(__file__).resolve().parent/'adapter/main.swift'
 for name in ['VisionAudioController.swift','VisionAudioRoute.swift']:paths[name]=root/'visionOSClient'/name
sha=lambda b:hashlib.sha256(b).hexdigest()
original={k:sha(p.read_bytes()) for k,p in paths.items()}
emitted={k:p.read_bytes() for k,p in paths.items()}
if '--adapter' in sys.argv:
 emitted['VisionAudioRoute.swift']=emitted['VisionAudioRoute.swift'].replace(b'import Network\n',b'').replace(b'import StreamProtocol\n',b'')
start=runner.index(" sources=[str(package/'DiscoveryPolicy.swift')")
end=runner.index(" record['commandExitCodes']=[]",start)
runner=runner[:start]+" commands=[['/usr/bin/xcrun','swiftc']+[str(package/n) for n in "+repr(list(paths))+ "]+['-o',str(output/'consent'),'-module-cache-path',cache],[str(output/'consent')]]\n"+runner[end:]
runner=runner.replace('CCRReconnect','CCRAudioConsent').replace('ccr-reconnect-output-','ccr-audio-consent-output-')
hashes={k:sha(data) for k,data in emitted.items()}
payload=json.dumps({'source':{k:base64.b64encode(data).decode() for k,data in emitted.items()},'hashes':hashes}).encode()
process=subprocess.Popen(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try: log,_=process.communicate(payload,timeout=600)
except subprocess.TimeoutExpired:
 process.terminate();log,_=process.communicate(timeout=30)
(out/(label+'.log')).write_bytes(log)
records=[line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
record={'exitCode':process.returncode,'transportPID':process.pid,'transportReaped':process.poll() is not None,'sourceHEAD':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'scope':'Native policy/controller/route with synthetic peer and player. AVAudioSession observers compile only on visionOS, not executed here. No network/audio/device or source-guard task transfer.','originalSourceSHA256':original,'emittedSHA256':hashes,'routeImportSubstitution':'Network and StreamProtocol imports removed; fixture supplies identity-only peer and source enum; all methods unchanged' if '--adapter' in sys.argv else None,'senderReceiverMatch':('INPUT_SHA256 '+sha(payload)).encode() in log,'sourceUnchanged':all(sha(p.read_bytes())==original[k] for k,p in paths.items()),'RAMRunnerReferenceSHA256':sha(reference.read_bytes()),'RAMRunnerSHA256':sha(runner.encode()),'remoteResult':json.loads(records[-1]) if records else None}
(out/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
for line in log.decode(errors='replace').splitlines():
 if line.startswith(('FAIL ','Vision audio consent:','Vision audio adapter:','error:')):print(line)
print(json.dumps({k:v for k,v in record.items() if k not in ['sourceSHA256','remoteResult']}))
if record['remoteResult']:print(json.dumps(record['remoteResult']))
sys.exit(process.returncode)

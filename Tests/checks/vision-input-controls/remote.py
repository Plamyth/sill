import base64,hashlib,json,os,pathlib,plistlib,re,signal,subprocess,sys,tempfile,uuid,shutil
raw=sys.stdin.buffer.read();print('INPUT_SHA256 '+hashlib.sha256(raw).hexdigest(),flush=True);p=json.loads(raw);raw=None
volume='CCRReconnect'+uuid.uuid4().hex[:10];disk=None;output=None;child=None;record={'runnerPID':os.getpid(),'childPIDs':[]}
def health():
 return {'swap':subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage'],text=True).strip(),'pressure':subprocess.check_output(['/usr/bin/memory_pressure','-Q'],text=True).strip(),'orca':subprocess.run(['/usr/bin/pgrep','-f','orca-server-1.4'],capture_output=True,text=True).stdout.splitlines()}
record['before']=health()
try:
 disk=subprocess.check_output(['/usr/bin/hdiutil','attach','-nomount','ram://131072'],text=True).strip()
 if not re.fullmatch(r'/dev/disk[0-9]+',disk): raise RuntimeError('unexpected RAM disk identity')
 subprocess.run(['/usr/sbin/diskutil','eraseVolume','HFS+',volume,disk],check=True,stdout=subprocess.DEVNULL,timeout=20)
 info=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',disk]));mount=pathlib.Path(info['MountPoint'])
 if info.get('VolumeName')!=volume or not 0<int(info['TotalSize'])<=70*1024*1024 or str(mount)!='/Volumes/'+volume: raise RuntimeError('RAM identity mismatch')
 package=mount/'input';package.mkdir(mode=0o700)
 for name,data in p['source'].items():
  relative=pathlib.PurePosixPath(name)
  if relative.is_absolute() or '..' in relative.parts: raise RuntimeError('invalid input path')
  b=base64.b64decode(data,validate=True)
  if hashlib.sha256(b).hexdigest()!=p['hashes'][name]: raise RuntimeError('input mismatch')
  f=package/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(b)
 record['inputHashesMatched']=True;original=p['hashes'];p=None
 output=pathlib.Path(tempfile.mkdtemp(prefix='ccr-reconnect-output-',dir='/private/tmp'))
 cache=str(output/'cache')
 sources=[str(package/n) for n in ['Client.swift','iOSClient/SessionLink.swift','iOSClient/KeyChords.swift','Sources/SillHost/KeyStrokes.swift','visionOSClient/VisionPointer.swift','visionOSClient/VisionInputSession.swift','visionOSClient/VisionInputDebt.swift','visionOSClient/VisionPresentation.swift','visionOSClient/VisionRemoteKey.swift','Tests/checks/vision-input-controls/SourceInputFence.swift','main.swift']]
 def module(name, source):
  return ['/usr/bin/xcrun','swiftc','-parse-as-library','-emit-module','-emit-object','-module-name',name,str(package/source),'-emit-module-path',str(output/(name+'.swiftmodule')),'-o',str(output/(name+'.o')),'-module-cache-path',cache]
 protocol=['/usr/bin/xcrun','swiftc','-parse-as-library','-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol']+[str(package/('Sources/StreamProtocol/'+name+'.swift')) for name in ['Input','Switcher','StreamMessage','Compatibility']]+['-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'StreamProtocol.o'),'-module-cache-path',cache]
 commands=[module('Network','Network.swift'),module('SwiftUI','SwiftUI.swift'),protocol,['/usr/bin/xcrun','swiftc','-package-name','sill','-I',str(output)]+sources+[str(output/(n+'.o')) for n in ['Network','SwiftUI','StreamProtocol']]+['-o',str(output/'controls'),'-module-cache-path',cache],[str(output/'controls')]]
 commands += [
  ['/usr/bin/xcrun','swiftc','-I',str(output),str(package/'iOSClient/KeyChords.swift'),str(package/'visionOSClient/VisionPointer.swift'),str(package/'visionOSClient/VisionInputFence.swift'),str(package/'visionOSClient/VisionTransition.swift'),str(package/'Tests/vision-pointer/main.swift'),str(output/'StreamProtocol.o'),'-o',str(output/'prior-pointer'),'-module-cache-path',cache], [str(output/'prior-pointer')],
  ['/usr/bin/xcrun','swiftc','-O',str(package/'iOSClient/SessionLink.swift')]+[str(p) for p in sorted((package/'Sources/StreamProtocol').glob('*.swift'))]+[str(package/'Tests/checks/fence/main.swift'),'-o',str(output/'legacy-fence'),'-module-cache-path',cache]
 ]
 commands += [[str(output/'legacy-fence'),mode] for mode in ['ok','nofence','timeout','oldcloses','hold','holdclosed','unhold','adoptfence','twofences','twomoves','holdfence','holdadopt','newsession','newsessionhold','count','remotehome','remotedead']]
 mutants={'debt':('Client.swift','mutants/debt/Client.swift','actual setter releases old peer atomically'),'route':('iOSClient/SessionLink.swift','mutants/route/SessionLink.swift','late old input refused after handover')}
 mutants['capture']=('Client.swift','mutants/capture/Client.swift','queued input revoked before submission cannot cross source update')
 mutants['generation']=('visionOSClient/VisionInputDebt.swift','visionOSClient/VisionPresentation.swift','mutants/generation/VisionInputDebt.swift','source change releases held input with original generation')
 mutants['admission']=('Client.swift','mutants/admission/Client.swift','awaiting fresh catalog blocks native transport before enqueue')
 mutants['controls']=('visionOSClient/VisionInputSession.swift','mutants/controls/VisionInputSession.swift','awaiting fresh catalog keeps native controls disabled')
 expectedFailures={}
 for name,(originalPath,replacement,witness) in mutants.items():
  variant=[str(package/replacement) if p==str(package/originalPath) else p for p in sources]
  executable=str(output/('mutant-'+name))
  commands += [['/usr/bin/xcrun','swiftc','-package-name','sill','-I',str(output)]+variant+[str(output/(n+'.o')) for n in ['Network','SwiftUI','StreamProtocol']]+['-o',executable,'-module-cache-path',cache],[executable]]
  expectedFailures[executable]=witness
 record['commandExitCodes']=[]
 for command in commands:
  child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  record['childPIDs'].append(child.pid)
  try: log,_=child.communicate(timeout=180)
  except subprocess.TimeoutExpired:
   os.killpg(child.pid,signal.SIGTERM)
   try: log,_=child.communicate(timeout=5)
   except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
  sys.stdout.buffer.write(log);sys.stdout.flush()
  if len(command)==1 and command[0] in expectedFailures:
   detected=child.returncode!=0 and expectedFailures[command[0]].encode() in log
   record.setdefault('mutants',[]).append({'name':pathlib.Path(command[0]).name,'runtimeExit':child.returncode,'specificWitness':expectedFailures[command[0]],'caught':detected})
   record['commandExitCodes'].append(0 if detected else 1)
  else: record['commandExitCodes'].append(child.returncode)
  if 'swiftc' in command and child.returncode: break
 record['exitCode']=0 if all(code==0 for code in record['commandExitCodes']) else 1
 record['memorySourcesUnchanged']=all(hashlib.sha256((package/n).read_bytes()).hexdigest()==h for n,h in original.items())
except Exception as e:
 record['error']=type(e).__name__+': '+str(e);record['exitCode']=2
finally:
 if child and child.poll() is None: os.killpg(child.pid,signal.SIGKILL);child.wait()
 record['childrenReaped']=child is None or child.poll() is not None
 if output: shutil.rmtree(output);record['outputRemoved']=not output.exists()
 if disk:
  r=subprocess.run(['/usr/bin/hdiutil','detach',disk],capture_output=True,text=True,timeout=20)
  record['detachCode']=r.returncode;record['sourceRemoved']=r.returncode==0 and not pathlib.Path('/Volumes',volume).exists()
 record['after']=health()
 print('RESULT_JSON '+json.dumps(record),flush=True)
sys.exit(record.get('exitCode',2) if record.get('sourceRemoved') and record.get('outputRemoved') else 2)
